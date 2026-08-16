@echo off
if "%AGENT_CHROME_DEBUG_PORT%"=="" set "AGENT_CHROME_DEBUG_PORT=9333"
node "%~dp0node_modules\chrome-devtools-mcp\build\src\bin\chrome-devtools-mcp.js" --browser-url=http://127.0.0.1:%AGENT_CHROME_DEBUG_PORT% --no-usage-statistics --no-performance-crux
