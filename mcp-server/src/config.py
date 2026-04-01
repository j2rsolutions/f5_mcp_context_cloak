"""Configuration for the Context Cloak MCP server."""

import os
from dataclasses import dataclass


@dataclass
class Config:
    postgres_host: str = os.getenv("POSTGRES_HOST", "localhost")
    postgres_port: int = int(os.getenv("POSTGRES_PORT", "5432"))
    postgres_db: str = os.getenv("POSTGRES_DB", "context_cloak")
    postgres_user: str = os.getenv("POSTGRES_USER", "mcpuser")
    postgres_password: str = os.getenv("POSTGRES_PASSWORD", "changeme-in-production")
    server_host: str = os.getenv("MCP_SERVER_HOST", "0.0.0.0")
    server_port: int = int(os.getenv("MCP_SERVER_PORT", "8080"))

    @property
    def dsn(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


config = Config()
