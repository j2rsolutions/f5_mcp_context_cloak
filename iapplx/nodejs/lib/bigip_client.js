'use strict';

var http = require('http');

var BIGIP_HOST = 'localhost';
var BIGIP_PORT = 8100;

function runTmsh(command, callback) {
    var postData = JSON.stringify({
        command: 'run',
        utilCmdArgs: '-c "tmsh ' + command.replace(/"/g, '\\"') + '"'
    });

    var options = {
        hostname: BIGIP_HOST,
        port: BIGIP_PORT,
        path: '/mgmt/tm/util/bash',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData),
            'Authorization': 'Basic ' + Buffer.from('admin:').toString('base64')
        }
    };

    var req = http.request(options, function (res) {
        var body = '';
        res.on('data', function (chunk) { body += chunk; });
        res.on('end', function () {
            try {
                var result = JSON.parse(body);
                var output = result.commandResult || '';
                callback(null, output.trim());
            } catch (e) {
                callback(new Error('Parse error: ' + body.substring(0, 200)), null);
            }
        });
    });

    req.on('error', function (e) { callback(e, null); });
    req.write(postData);
    req.end();
}

function runTmshBatch(commands, callback) {
    var results = [];
    var errors = [];
    var idx = 0;

    function next() {
        if (idx >= commands.length) {
            callback(errors.length > 0 ? new Error(errors.join('; ')) : null, results);
            return;
        }
        var cmd = commands[idx++];
        runTmsh(cmd, function (err, result) {
            if (err) errors.push(cmd.substring(0, 60) + '... => ' + err.message);
            results.push({ command: cmd.substring(0, 80), result: result, error: err ? err.message : null });
            next();
        });
    }
    next();
}

/**
 * Write file using base64 encoding to avoid all quoting/escaping issues.
 */
function writeFile(path, content, callback) {
    var b64 = Buffer.from(content).toString('base64');
    var postData = JSON.stringify({
        command: 'run',
        utilCmdArgs: '-c "echo ' + b64 + ' | base64 -d > ' + path + '"'
    });

    var options = {
        hostname: BIGIP_HOST,
        port: BIGIP_PORT,
        path: '/mgmt/tm/util/bash',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData),
            'Authorization': 'Basic ' + Buffer.from('admin:').toString('base64')
        }
    };

    var req = http.request(options, function (res) {
        var body = '';
        res.on('data', function (chunk) { body += chunk; });
        res.on('end', function () { callback(null); });
    });
    req.on('error', function (e) { callback(e); });
    req.write(postData);
    req.end();
}

module.exports = {
    runTmsh: runTmsh,
    runTmshBatch: runTmshBatch,
    writeFile: writeFile
};
