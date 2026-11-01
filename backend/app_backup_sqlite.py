"""AJ Face Attendance: mobile browser interface + Python face recognition API.
Prototype only: LBPH is NOT spoof-resistant; use only with consent and HTTPS.
"""
import csv
import io
import os
import re
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from datetime import date, datetime, time
from pathlib import Path

import cv2
import numpy as np
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
TRAINER = ROOT / "trainer"
PHOTOS = DATA / "faces"
for folder in (DATA, TRAINER, PHOTOS):
    folder.mkdir(parents=True, exist_ok=True)
DB = DATA / "attendance.db"
MODEL = TRAINER / "trainer.yml"
CASCADE = cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
ADMIN_USER = os.environ.get("AJ_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("AJ_ADMIN_PASSWORD", "")
if len(ADMIN_PASSWORD) < 16:
    raise RuntimeError("Set AJ_ADMIN_PASSWORD to a unique password of at least 16 characters")

app = FastAPI(title="AJ Face Attendance", docs_url=None, redoc_url=None)
auth_scheme = HTTPBasic()
lock = threading.RLock()


def require_admin(credentials: HTTPBasicCredentials = Depends(auth_scheme)):
    if not (secrets.compare_digest(credentials.username.encode(), ADMIN_USER.encode()) and
            secrets.compare_digest(credentials.password.encode(), ADMIN_PASSWORD.encode())):
        raise HTTPException(401, "Invalid login", headers={"WWW-Authenticate": "Basic"})
    return credentials.username


@contextmanager
def database():
    connection = sqlite3.connect(DB, timeout=15)
    connection.row_factory = sqlite3.Row
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


with database() as db:
    db.executescript("""
        CREATE TABLE IF NOT EXISTS students (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, team TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS attendance (
            student_id TEXT NOT NULL, day TEXT NOT NULL,
            check_in TEXT, check_out TEXT,
            PRIMARY KEY(student_id, day),
            FOREIGN KEY(student_id) REFERENCES students(id)
        );
    """)


def get_face(image_bytes):
    if len(image_bytes) > 5 * 1024 * 1024:
        raise HTTPException(413, "Photo must be under 5 MB")
    image = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(400, "Invalid image")
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    detector = cv2.CascadeClassifier(CASCADE)
    if detector.empty():
        raise HTTPException(500, "Face detector unavailable")
    faces = detector.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(65, 65))
    if len(faces) != 1:
        raise HTTPException(422, "Exactly one visible face is required")
    x, y, w, h = faces[0]
    return cv2.resize(gray[y:y+h, x:x+w], (160, 160))


def face_samples():
    samples, ids = [], []
    with database() as db:
        students = [r["id"] for r in db.execute("SELECT id FROM students ORDER BY id")]
    for index, student_id in enumerate(students):
        for path in (PHOTOS / student_id).glob("*.png"):
            image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
            if image is not None:
                samples.append(image)
                ids.append(index)
    return students, samples, ids


def predict(image):
    if not MODEL.exists():
        raise HTTPException(409, "Train the face model first")
    students, _, _ = face_samples()
    # Labels are stored with the model to keep numeric IDs stable.
    labels_path = TRAINER / "labels.txt"
    if not labels_path.exists():
        raise HTTPException(409, "Model labels missing; retrain")
    labels = labels_path.read_text(encoding="utf-8").splitlines()
    recognizer = cv2.face.LBPHFaceRecognizer_create()
    try:
        recognizer.read(str(MODEL))
        label, distance = recognizer.predict(image)
    except cv2.error:
        raise HTTPException(409, "Invalid model; retrain")
    # LBPH distance is NOT a calibrated probability.
    if label < 0 or label >= len(labels) or distance > 65:
        raise HTTPException(404, "Unknown face; attendance not recorded")
    return labels[label], round(float(distance), 1)


def status_for(check_in, check_out, day):
    if not check_in:
        return "Absent"
    if check_out and datetime.fromisoformat(check_out).time() < time(15, 0):
        return "Half Day"
    if not check_out and (day < date.today().isoformat() or
                          (day == date.today().isoformat() and datetime.now().time() >= time(18, 0))):
        return "Half Day"
    if not check_out:
        return "Checked In"
    if datetime.fromisoformat(check_in).time() >= time(9, 0):
        return "Late"
    return "Present"


@app.get("/", response_class=HTMLResponse)
def homepage():
    return (ROOT / "templates" / "index.html").read_text(encoding="utf-8")


@app.get("/logo.png")
def logo():
    return FileResponse(ROOT / "assets" / "aj_logo.png", media_type="image/png")


@app.get("/api/health")
def health(_: str = Depends(require_admin)):
    return {"status": "ok", "model_loaded": MODEL.exists(),
            "warning": "LBPH does not detect photo or video spoofing"}


@app.get("/api/students")
def students(_: str = Depends(require_admin)):
    with database() as db:
        return [dict(r) for r in db.execute("SELECT * FROM students ORDER BY name")]


@app.post("/api/students")
def register(student_id: str = Form(...), name: str = Form(...), team: str = Form(...),
             _: str = Depends(require_admin)):
    student_id, name, team = student_id.strip(), name.strip(), team.strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{2,32}", student_id):
        raise HTTPException(400, "Student ID: 2–32 letters, numbers, - or _")
    if not name or not team or len(name) > 100 or len(team) > 100:
        raise HTTPException(400, "Enter valid name and team")
    with database() as db:
        try:
            db.execute("INSERT INTO students VALUES (?, ?, ?, ?)",
                       (student_id, name, team, datetime.now().isoformat(timespec="seconds")))
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Student ID already registered")
    return {"message": "Student registered. Capture at least 5 face photos, then train."}


@app.post("/api/enroll/{student_id}")
async def enroll(student_id: str, photo: UploadFile = File(...), _: str = Depends(require_admin)):
    with database() as db:
        if not db.execute("SELECT 1 FROM students WHERE id=?", (student_id,)).fetchone():
            raise HTTPException(404, "Student not found")
    face = get_face(await photo.read())
    folder = PHOTOS / student_id
    folder.mkdir(parents=True, exist_ok=True)
    count = len(list(folder.glob("*.png")))
    if count >= 30:
        raise HTTPException(409, "Maximum 30 photos per student")
    cv2.imwrite(str(folder / f"{count+1:03d}.png"), face)
    return {"message": "Face sample saved", "samples": count + 1}


@app.post("/api/train")
def train(_: str = Depends(require_admin)):
    with lock:
        labels, samples, ids = face_samples()
        if not samples:
            raise HTTPException(409, "Register students and capture face photos first")
        counts = {label: ids.count(i) for i, label in enumerate(labels)}
        if any(count < 5 for count in counts.values()):
            raise HTTPException(409, "Every registered student needs at least 5 photos")
        recognizer = cv2.face.LBPHFaceRecognizer_create()
        recognizer.train(samples, np.array(ids, dtype=np.int32))
        recognizer.write(str(MODEL))
        (TRAINER / "labels.txt").write_text("\n".join(labels) + "\n", encoding="utf-8")
    return {"message": "Training completed", "students": len(labels), "photos": len(samples)}


@app.post("/api/scan")
async def scan(action: str = Form(...), photo: UploadFile = File(...),
               _: str = Depends(require_admin)):
    if action not in ("in", "out", "verify"):
        raise HTTPException(400, "Action must be in, out, or verify")
    face = get_face(await photo.read())
    with lock:
        student_id, distance = predict(face)
        with database() as db:
            student = db.execute("SELECT * FROM students WHERE id=?", (student_id,)).fetchone()
            if student is None:
                raise HTTPException(404, "Student mapping missing")
            if action == "verify":
                return {"student": dict(student), "distance": distance, "saved": False}
            now = datetime.now().isoformat(timespec="seconds")
            day = date.today().isoformat()
            db.execute("INSERT OR IGNORE INTO attendance(student_id, day) VALUES (?, ?)",
                       (student_id, day))
            row = db.execute("SELECT * FROM attendance WHERE student_id=? AND day=?",
                             (student_id, day)).fetchone()
            if action == "in":
                if row["check_in"]:
                    raise HTTPException(409, "Already checked in today")
                db.execute("UPDATE attendance SET check_in=? WHERE student_id=? AND day=?",
                           (now, student_id, day))
            else:
                if not row["check_in"]:
                    raise HTTPException(409, "Check in first")
                if row["check_out"]:
                    raise HTTPException(409, "Already checked out today")
                db.execute("UPDATE attendance SET check_out=? WHERE student_id=? AND day=?",
                           (now, student_id, day))
    return {"student": dict(student), "action": action, "time": now,
            "distance": distance, "saved": True}


@app.get("/api/attendance")
def attendance(day: str = "", _: str = Depends(require_admin)):
    day = day or date.today().isoformat()
    try:
        date.fromisoformat(day)
    except ValueError:
        raise HTTPException(400, "Use YYYY-MM-DD")
    with database() as db:
        rows = db.execute("""
            SELECT s.id, s.name, s.team, a.check_in, a.check_out
            FROM students s LEFT JOIN attendance a
            ON s.id=a.student_id AND a.day=? ORDER BY s.name
        """, (day,)).fetchall()
    return [{**dict(r), "day": day,
             "status": status_for(r["check_in"], r["check_out"], day)} for r in rows]


@app.get("/api/export.csv")
def export(day: str = "", _: str = Depends(require_admin)):
    rows = attendance(day, _)
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=["id", "name", "team", "day", "check_in", "check_out", "status"])
    writer.writeheader()
    writer.writerows(rows)
    filename = f"AJ_attendance_{day or date.today().isoformat()}.csv"
    return StreamingResponse(iter([stream.getvalue()]), media_type="text/csv",
                             headers={"Content-Disposition": f'attachment; filename="{filename}"'})


@app.get("/api/dashboard")
def dashboard(_: str = Depends(require_admin)):
    rows = attendance("", _)
    counts = {"Present": 0, "Late Login": 0, "Half Day": 0, "Absent": 0}
    for row in rows:
        status = row["status"]
        if status in counts:
            counts[status] += 1
    return {"total": len(rows), "counts": counts, "rows": rows}
