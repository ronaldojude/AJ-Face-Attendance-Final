$env:AJ_ADMIN_USER = "admin"
if (-not $env:AJ_ADMIN_PASSWORD) { throw "Set AJ_ADMIN_PASSWORD in this terminal first (16+ characters)" }
python -m uvicorn app:app --host 0.0.0.0 --port 8000
