AJ Face Attendance PostgreSQL migration

1. Back up your current backend/app.py and attendance.db.
2. Copy app.py and requirements.txt into backend.
3. Set DATABASE_URL, AJ_ADMIN_USER, AJ_ADMIN_PASSWORD in backend/.env (do not commit).
4. Install: python -m pip install -r requirements.txt
5. Start: python -m uvicorn app:app --host 127.0.0.1 --port 8000
6. Test /api/health with HTTP Basic authentication.

IMPORTANT: This migration does NOT migrate existing SQLite records or make face images/trainer persistent on Render. Existing local data is untouched.
Deploy only after private persistent face file storage and appropriate access controls are configured.
