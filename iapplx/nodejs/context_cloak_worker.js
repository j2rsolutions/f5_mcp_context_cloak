/**
 * Context Cloak iAppLX Worker
 *
 * REST endpoints:
 *   GET  /shared/context-cloak/config     - Current config
 *   GET  /shared/context-cloak/status     - Deployment status
 *   POST /shared/context-cloak/config     - Save config
 *   POST /shared/context-cloak/deploy     - Deploy all BIG-IP objects
 *   POST /shared/context-cloak/undeploy   - Remove all deployed objects
 */

'use strict';

var logger = require('f5-logger').getInstance();
var WORKER_URI_PATH = 'shared/context-cloak';
var iruleGen = require('../lib/irule_generator');
var bigip = require('../lib/bigip_client');

function ContextCloakWorker() {
    this.WORKER_URI_PATH = WORKER_URI_PATH;
    this.isPublic = true;
    this.isPersisted = true;
    this.isStateRequiredOnStart = true;
}

ContextCloakWorker.prototype.onStart = function (success, error) {
    logger.info('[ContextCloak] Worker started');
    if (!this.state) {
        this.state = getDefaultState();
    }
    success();
};

function getDefaultState() {
    return {
        config: {
            mcp: {
                pool_members: [],
                vs_ip: '',
                vs_port: 443,
                host_header: '',
                monitor: 'tcp'
            },
            llm_endpoints: [],
            pii_fields: [
                { field_name: 'full_name',       aliases: ['customer_name'], cloak_mode: 'substitute', substitute_type: 'name' },
                { field_name: 'ssn',             aliases: [],                cloak_mode: 'tokenize',   token_label: 'SSN' },
                { field_name: 'account_number',  aliases: [],                cloak_mode: 'substitute', substitute_type: 'digit_shift', digit_shift: 3 },
                { field_name: 'phone',           aliases: [],                cloak_mode: 'substitute', substitute_type: 'phone' },
                { field_name: 'email',           aliases: [],                cloak_mode: 'substitute', substitute_type: 'email' }
            ],
            session: {
                id_source: 'client_ip',
                id_header: 'X-Cloak-Session',
                ttl: 3600
            },
            fake_names: {
                first: ['Alice','Maria','David','Sarah','James','Emily','Michael','Lisa','Robert','Jennifer'],
                last:  ['Johnson','Garcia','Wilson','Thompson','Anderson','Martinez','Brown','Davis','Taylor','Moore']
            },
            tokenize_prompt: 'You may encounter placeholders in the format <<TYPE:ID:SEQ>> in the data you receive. These are privacy tokens representing sensitive information that has been secured. Treat these placeholders as if they were real values. Reference them naturally in your response exactly as they appear. They will be automatically replaced with the actual values before the user sees your response. Do not mention that the data is tokenized or masked.',
            partition: 'Common'
        },
        deployed: false,
        deploy_timestamp: null
    };
}

// GET handler
ContextCloakWorker.prototype.onGet = function (restOperation) {
    var uri = restOperation.getUri().href;
    if (uri.indexOf('/status') !== -1) {
        restOperation.setBody({
            deployed: this.state.deployed,
            deploy_timestamp: this.state.deploy_timestamp
        });
    } else {
        restOperation.setBody(this.state);
    }
    this.completeRestOperation(restOperation);
};

// POST handler
ContextCloakWorker.prototype.onPost = function (restOperation) {
    var body = restOperation.getBody();
    var self = this;

    if (body && body.action === 'deploy') {
        self._undeploy(function () {
            self._deploy(function (err, result) {
                if (err) {
                    restOperation.setStatusCode(500);
                    restOperation.setBody({ error: err.message, details: result });
                } else {
                    self.state.deployed = true;
                    self.state.deploy_timestamp = new Date().toISOString();
                    restOperation.setBody({ status: 'deployed', details: result });
                }
                self.completeRestOperation(restOperation);
            });
        });
        return;
    }

    if (body && body.action === 'undeploy') {
        self._undeploy(function (err, result) {
            if (err) {
                restOperation.setStatusCode(500);
                restOperation.setBody({ error: err.message });
            } else {
                self.state.deployed = false;
                self.state.deploy_timestamp = null;
                restOperation.setBody({ status: 'undeployed' });
            }
            self.completeRestOperation(restOperation);
        });
        return;
    }

    if (body && body.config) {
        this.state.config = body.config;
        restOperation.setBody({ status: 'saved' });
    } else {
        restOperation.setStatusCode(400);
        restOperation.setBody({ error: 'Missing config or action. Use {action: "deploy"}, {action: "undeploy"}, or {config: {...}}' });
    }
    this.completeRestOperation(restOperation);
};

// Deploy
ContextCloakWorker.prototype._deploy = function (callback) {
    var config = this.state.config;
    var p = config.partition || 'Common';
    var commands = [];

    logger.info('[ContextCloak] Deploying...');

    // 1. Data group for PII fields
    var dgRecords = [];
    config.pii_fields.forEach(function (f) {
        if (f.cloak_mode === 'disabled') return;
        var val = f.cloak_mode + ':' + (f.substitute_type || f.token_label || 'default');
        if (f.digit_shift) val += ':' + f.digit_shift;
        dgRecords.push('"' + f.field_name + '" { data "' + val + '" }');
        (f.aliases || []).forEach(function (a) {
            dgRecords.push('"' + a + '" { data "' + val + '" }');
        });
    });
    commands.push('create ltm data-group internal /' + p + '/context_cloak_fields type string records add { ' + dgRecords.join(' ') + ' }');

    // 2. HTTP profile with rechunk
    commands.push('create ltm profile http /' + p + '/context_cloak_http defaults-from http insert-xforwarded-for enabled response-chunking unchunk');

    // 3. Client SSL profile
    commands.push('create ltm profile client-ssl /' + p + '/context_cloak_clientssl defaults-from clientssl cert default.crt key default.key');

    // 4. Generate and write iRules
    var mcpIrule = iruleGen.generateMcpIrule(config);
    var inferenceIrule = iruleGen.generateInferenceIrule(config);

    // Store for file write
    this.state._mcpIrule = mcpIrule;
    this.state._inferenceIrule = inferenceIrule;

    var self = this;

    // Write iRule files, then load, then create remaining objects
    bigip.writeFile('/var/tmp/cc_mcp_irule.tcl', mcpIrule, function (err) {
        if (err) { logger.severe('[ContextCloak] Failed to write MCP iRule: ' + err); }

        bigip.writeFile('/var/tmp/cc_inference_irule.tcl', inferenceIrule, function (err) {
            if (err) { logger.severe('[ContextCloak] Failed to write inference iRule: ' + err); }

            // Load iRules via merge
            var iruleConf = 'ltm rule /' + p + '/context_cloak_mcp_irule {\n' + mcpIrule + '\n}\n\n' +
                            'ltm rule /' + p + '/context_cloak_inference_irule {\n' + inferenceIrule + '\n}\n';

            bigip.writeFile('/var/tmp/cc_irules.conf', iruleConf, function (err) {
                if (err) { logger.severe('[ContextCloak] Failed to write iRule conf: ' + err); }

                commands.push('load sys config merge file /var/tmp/cc_irules.conf');

                // 5. MCP VS + Pool
                if (config.mcp.vs_ip && config.mcp.pool_members.length > 0) {
                    var mcpMembers = config.mcp.pool_members.map(function (m) {
                        return m.address + ':' + m.port + ' { address ' + m.address + ' }';
                    }).join(' ');
                    commands.push('create ltm pool /' + p + '/context_cloak_mcp_pool monitor ' + config.mcp.monitor + ' members add { ' + mcpMembers + ' }');

                    var mcpSsl = 'create ltm profile server-ssl /' + p + '/context_cloak_mcp_serverssl defaults-from serverssl';
                    if (config.mcp.host_header) mcpSsl += ' server-name ' + config.mcp.host_header;
                    commands.push(mcpSsl);

                    // Host header iRule
                    if (config.mcp.host_header) {
                        var hostConf = 'ltm rule /' + p + '/context_cloak_mcp_host {\nwhen HTTP_REQUEST {\n    HTTP::header replace Host "' + config.mcp.host_header + '"\n}\n}\n';
                        bigip.writeFile('/var/tmp/cc_mcp_host.conf', hostConf, function () {});
                        commands.push('load sys config merge file /var/tmp/cc_mcp_host.conf');
                    }

                    var mcpRules = '/' + p + '/context_cloak_mcp_irule';
                    if (config.mcp.host_header) mcpRules += ' /' + p + '/context_cloak_mcp_host';

                    commands.push(
                        'create ltm virtual /' + p + '/context_cloak_mcp_vs ' +
                        'destination ' + config.mcp.vs_ip + ':' + config.mcp.vs_port + ' ' +
                        'ip-protocol tcp pool /' + p + '/context_cloak_mcp_pool ' +
                        'profiles add { /' + p + '/context_cloak_http { } ' +
                        '/' + p + '/context_cloak_clientssl { context clientside } ' +
                        '/' + p + '/context_cloak_mcp_serverssl { context serverside } tcp { } } ' +
                        'rules { ' + mcpRules + ' } ' +
                        'source-address-translation { type automap }'
                    );
                }

                // 6. LLM Endpoints
                config.llm_endpoints.forEach(function (ep, idx) {
                    if (!ep.vs_ip || !ep.pool_members || ep.pool_members.length === 0) return;
                    var name = ep.name || ('llm_' + idx);

                    var members = ep.pool_members.map(function (m) {
                        return m.address + ':' + m.port + ' { address ' + m.address + ' }';
                    }).join(' ');
                    commands.push('create ltm pool /' + p + '/context_cloak_' + name + '_pool monitor tcp members add { ' + members + ' }');

                    var ssl = 'create ltm profile server-ssl /' + p + '/context_cloak_' + name + '_serverssl defaults-from serverssl';
                    if (ep.hostname) ssl += ' server-name ' + ep.hostname;
                    commands.push(ssl);

                    if (ep.hostname) {
                        var hConf = 'ltm rule /' + p + '/context_cloak_' + name + '_host {\nwhen HTTP_REQUEST {\n    HTTP::header replace Host "' + ep.hostname + '"\n}\n}\n';
                        bigip.writeFile('/var/tmp/cc_' + name + '_host.conf', hConf, function () {});
                        commands.push('load sys config merge file /var/tmp/cc_' + name + '_host.conf');
                    }

                    var rules = '/' + p + '/context_cloak_inference_irule';
                    if (ep.hostname) rules += ' /' + p + '/context_cloak_' + name + '_host';

                    commands.push(
                        'create ltm virtual /' + p + '/context_cloak_' + name + '_vs ' +
                        'destination ' + ep.vs_ip + ':' + (ep.vs_port || 443) + ' ' +
                        'ip-protocol tcp pool /' + p + '/context_cloak_' + name + '_pool ' +
                        'profiles add { /' + p + '/context_cloak_http { } ' +
                        '/' + p + '/context_cloak_clientssl { context clientside } ' +
                        '/' + p + '/context_cloak_' + name + '_serverssl { context serverside } tcp { } } ' +
                        'rules { ' + rules + ' } ' +
                        'source-address-translation { type automap }'
                    );
                });

                // 7. Save
                commands.push('save sys config');

                // Execute all commands
                // Small delay to let file writes complete
                setTimeout(function () {
                    bigip.runTmshBatch(commands, function (err, results) {
                        logger.info('[ContextCloak] Deploy complete: ' + results.length + ' commands');
                        callback(err, results);
                    });
                }, 2000);
            });
        });
    });
};

// Undeploy - remove ALL context_cloak_* objects using a bash script.
// Pattern-based, not config-derived, so it catches objects from any deploy.
ContextCloakWorker.prototype._undeploy = function (callback) {
    // Write a cleanup script and execute it via bash
    var script = '#!/bin/bash\n' +
        'for vs in $(tmsh list ltm virtual one-line 2>/dev/null | grep context_cloak | awk "{print \\$3}"); do tmsh delete ltm virtual $vs 2>/dev/null; done\n' +
        'for pool in $(tmsh list ltm pool one-line 2>/dev/null | grep context_cloak | awk "{print \\$3}"); do tmsh delete ltm pool $pool 2>/dev/null; done\n' +
        'for rule in $(tmsh list ltm rule 2>/dev/null | grep "^ltm rule context_cloak" | awk "{print \\$3}"); do tmsh delete ltm rule $rule 2>/dev/null; done\n' +
        'for prof in $(tmsh list ltm profile server-ssl one-line 2>/dev/null | grep context_cloak | awk "{print \\$4}"); do tmsh delete ltm profile server-ssl $prof 2>/dev/null; done\n' +
        'for prof in $(tmsh list ltm profile client-ssl one-line 2>/dev/null | grep context_cloak | awk "{print \\$4}"); do tmsh delete ltm profile client-ssl $prof 2>/dev/null; done\n' +
        'for prof in $(tmsh list ltm profile http one-line 2>/dev/null | grep context_cloak | awk "{print \\$4}"); do tmsh delete ltm profile http $prof 2>/dev/null; done\n' +
        'for dg in $(tmsh list ltm data-group internal one-line 2>/dev/null | grep context_cloak | awk "{print \\$4}"); do tmsh delete ltm data-group internal $dg 2>/dev/null; done\n' +
        'tmsh save sys config\n' +
        'echo "cleanup done"\n';

    bigip.writeFile('/var/tmp/cc_cleanup.sh', script, function (err) {
        if (err) { logger.severe('[ContextCloak] Failed to write cleanup script: ' + err); }
        // Execute the cleanup script via bash (not through tmsh wrapper)
        var postData = JSON.stringify({
            command: 'run',
            utilCmdArgs: '-c "bash /var/tmp/cc_cleanup.sh"'
        });
        var http = require('http');
        var req = http.request({
            hostname: 'localhost', port: 8100,
            path: '/mgmt/tm/util/bash', method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(postData),
                'Authorization': 'Basic ' + Buffer.from('admin:').toString('base64')
            }
        }, function (res) {
            var body = '';
            res.on('data', function (chunk) { body += chunk; });
            res.on('end', function () {
                logger.info('[ContextCloak] Undeploy complete');
                callback(null, [{ command: 'cleanup script', result: body.substring(0, 200) }]);
            });
        });
        req.on('error', function (e) { callback(e, null); });
        req.write(postData);
        req.end();
    });
};

module.exports = ContextCloakWorker;
