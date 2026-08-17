#!/usr/bin/env python3
"""Reconcile bank CSV exports against Zoho Books and emit import files for
whatever's missing.

Used Aug 2026 to backfill ~100 genuinely missing transactions across six
accounts and to identify ~150 duplicate uncategorized lines (see ROADMAP.md).
Keep for future statement checks (e.g. the AMEX 2026 history, pending).

Usage:
  python3 scripts/reconcile_statements.py            # report + write missing-import CSVs

How it works:
  - Parses each configured CSV (per-bank formats below) into (date, amount) rows.
  - Fetches the account's FULL Zoho transaction pool. NOTE the Zoho quirks:
    listings exclude uncategorized statement lines unless queried with
    status=uncategorized, and date_start/date_end are ignored — so we fetch
    filter_by=Status.All AND status=uncategorized, merge, and window client-side.
  - Statement-anchored matching: each statement row consumes at most one Zoho
    transaction with the same amount within ±4 days (prefers the closest date).
  - Unmatched statement rows  -> "missing" -> written to an import CSV
    (Date, Description, Withdrawals, Deposits) for Zoho's statement importer.
  - Unmatched *uncategorized* Zoho rows inside the statement window that have a
    matched twin (same amount ±4d) -> reported as duplicate suspects.

Reads credentials from ~/.zoho-ai-bookkeeper/config.json. Read-only except the
CSV files it writes locally.
"""
import csv
import json
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STATEMENTS = REPO / "tmp" / "z_Archived"   # where bank exports live
OUT_DIR = REPO / "tmp"
CONFIG = json.load(open(Path.home() / ".zoho-ai-bookkeeper" / "config.json"))
_Z = CONFIG["zoho"]


def _cfg(snake, camel):
    return _Z.get(snake) or _Z.get(camel)


ORG = _cfg("organization_id", "organizationId")


def get_token():
    body = urllib.parse.urlencode({
        "refresh_token": _cfg("refresh_token", "refreshToken"),
        "client_id": _cfg("client_id", "clientId"),
        "client_secret": _cfg("client_secret", "clientSecret"),
        "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request(
        "https://accounts.zoho.com/oauth/v2/token", data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    return json.load(urllib.request.urlopen(req))["access_token"]


TOKEN = get_token()


def fetch(account_id, extra):
    txs, page = [], 1
    while True:
        params = {"organization_id": ORG, "account_id": account_id,
                  "page": page, "per_page": 200}
        params.update(extra)
        req = urllib.request.Request(
            f"https://www.zohoapis.com/books/v3/banktransactions?{urllib.parse.urlencode(params)}",
            headers={"Authorization": f"Zoho-oauthtoken {TOKEN}"})
        data = json.load(urllib.request.urlopen(req))
        txs += data.get("banktransactions", [])
        if data.get("page_context", {}).get("has_more_page"):
            page += 1
        else:
            break
    return txs


def full_pool(account_id):
    """All transactions: Status.All misses uncategorized lines, so merge both."""
    return fetch(account_id, {"filter_by": "Status.All"}) + fetch(account_id, {"status": "uncategorized"})


def num(s):
    s = (s or "").replace(",", "").replace("$", "").strip()
    return float(s) if s else 0.0


# --- Per-bank parsers: yield {date, description, out (>0), inflow (>0)} ---

def parse_capitalone(path):
    for r in csv.DictReader(open(path)):
        if r.get("Transaction Date"):
            yield {"date": datetime.strptime(r["Transaction Date"], "%Y-%m-%d").date(),
                   "description": r["Description"].strip(),
                   "out": num(r.get("Debit")), "inflow": num(r.get("Credit"))}


def parse_chase(path, datecol="Transaction Date"):
    """Chase cards use Transaction Date; Chase checking uses Posting Date."""
    for r in csv.DictReader(open(path)):
        if r.get(datecol):
            a = num(r.get("Amount"))
            yield {"date": datetime.strptime(r[datecol], "%m/%d/%Y").date(),
                   "description": r["Description"].strip(),
                   "out": -a if a < 0 else 0.0, "inflow": a if a > 0 else 0.0}


def parse_citi(path):
    for r in csv.DictReader(open(path)):
        if r.get("Status", "").strip() == "Cleared" and r.get("Date"):
            d, c = num(r.get("Debit")), num(r.get("Credit"))
            yield {"date": datetime.strptime(r["Date"].strip(), "%m/%d/%Y").date(),
                   "description": r["Description"].strip(),
                   "out": d if d > 0 else 0.0, "inflow": -c if c < 0 else c}


def parse_barclays(path):
    with open(path) as f:
        reader = csv.reader(f)
        on = False
        for row in reader:
            if not on:
                on = row and row[0].strip() == "Transaction Date"
                continue
            if len(row) >= 4 and row[0].strip():
                a = num(row[3])
                yield {"date": datetime.strptime(row[0].strip(), "%m/%d/%Y").date(),
                       "description": row[1].strip(),
                       "out": -a if a < 0 else 0.0, "inflow": a if a > 0 else 0.0}


# --- Account configuration: (name, zoho account id, parser calls) ---
# Add new statements here (e.g. the AMEX 2026 export when it arrives).

def statement_rows():
    return [
        ("Barclays", "8256174000000122151",
         list(parse_barclays(STATEMENTS / "CreditCard_20250101_20260817.csv"))),
        ("BJs", "8256174000000093899",
         list(parse_capitalone(STATEMENTS / "CapitalOneBJs-2026-08-17_transaction_download.csv"))
         + list(parse_capitalone(STATEMENTS / "CapitalOneBJs-2026-08-17_transaction_download-2.csv"))),
        ("InkCash", "8256174000000093355",
         list(parse_chase(STATEMENTS / "ChaseInkCash5846_Activity_20260817.csv"))),
        ("United", "8256174000000093365",
         list(parse_chase(STATEMENTS / "ChaseUnited9009_Activity_20260817.csv"))),
        ("Checking", "8256174000000093345",
         list(parse_chase(STATEMENTS / "ChaseChecking0673_Activity_20260817.csv", "Posting Date"))),
        ("Citi", "8256174000000093713",
         list(parse_citi(STATEMENTS / "CitiAAdvantageBusiness-Last year (2025).CSV"))
         + list(parse_citi(STATEMENTS / "CitiAAdvantageBusiness-Year to date.CSV"))),
        # AMEX Amazon Business ("8256174000000093777"): awaiting 2026 history from Amex/US Bank
    ]


def main():
    for name, account_id, rows in statement_rows():
        pool = [{"date": datetime.strptime(t["date"], "%Y-%m-%d").date(),
                 "amount": round(t["amount"], 2), "status": t.get("status"), "used": False}
                for t in full_pool(account_id)]
        start = min(r["date"] for r in rows)
        end = max(r["date"] for r in rows)

        missing = []
        for row in sorted(rows, key=lambda r: r["date"]):
            target = round(row["out"] or row["inflow"], 2)
            if target <= 0:
                continue
            best = None
            for p in pool:
                if p["used"] or abs(p["amount"] - target) >= 0.01:
                    continue
                delta = abs((p["date"] - row["date"]).days)
                if delta <= 4 and (best is None or delta < best[0]):
                    best = (delta, p)
            if best:
                best[1]["used"] = True
            else:
                missing.append(row)

        matched = [p for p in pool if p["used"]]
        suspects = [
            p for p in pool
            if not p["used"] and p["status"] == "uncategorized" and start <= p["date"] <= end
            and any(m for m in matched
                    if abs(m["amount"] - p["amount"]) < 0.01 and abs((m["date"] - p["date"]).days) <= 4)
        ]

        print(f"{name:9} statement {len(rows):4} ({start}..{end}) | zoho {len(pool):4} | "
              f"missing {len(missing):3} | duplicate suspects {len(suspects):3}")

        if missing:
            out = OUT_DIR / f"{name}-missing-zoho-import.csv"
            with open(out, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["Date", "Description", "Withdrawals", "Deposits"])
                for r in missing:
                    w.writerow([r["date"].strftime("%m/%d/%Y"), r["description"],
                                f"{r['out']:.2f}" if r["out"] else "",
                                f"{r['inflow']:.2f}" if r["inflow"] else ""])
            print(f"    wrote {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
