
import os
import psycopg
from dotenv import load_dotenv

load_dotenv()

database_url = os.environ.get("DATABASE_URL")

if not database_url:
    raise RuntimeError("DATABASE_URL is missing from .env")

with psycopg.connect(database_url, connect_timeout=15) as conn:
    with conn.cursor() as cursor:
        cursor.execute("SELECT current_database(), current_user")
        result = cursor.fetchone()

print("Supabase PostgreSQL connection successful!")
print("Database:", result[0])
print("User:", result[1])
