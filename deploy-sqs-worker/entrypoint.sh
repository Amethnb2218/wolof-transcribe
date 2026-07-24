#!/bin/bash
# Start health server in background, then run SQS worker in foreground
python health_server.py &
exec python worker.py
