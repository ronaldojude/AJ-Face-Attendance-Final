
from urllib.parse import quote

username = input("Supabase database username: ").strip()
password = input("Supabase database password: ")
host = input("Supabase database host: ").strip()
port = input("Port [5432]: ").strip() or "5432"

encoded_username = quote(username, safe="")
encoded_password = quote(password, safe="")

url = (
    f"postgresql://{encoded_username}:"
    f"{encoded_password}@{host}:{port}/postgres"
)

print("\nCopy the following URL into DATABASE_URL in your .env file:")
print(url)
