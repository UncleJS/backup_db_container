import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/session";

const API_BASE = process.env.API_INTERNAL_URL ?? "http://localhost:3001";

function apiHeaders() {
  return {
    Authorization: `Bearer ${process.env.INTERNAL_API_SECRET ?? ""}`,
    "Content-Type": "application/json",
  };
}

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const res = await fetch(`${API_BASE}/trigger`, {
      method: "POST",
      headers: apiHeaders(),
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err) {
    return NextResponse.json({ error: String(err) }, { status: 502 });
  }
}

export async function GET(req: NextRequest) {
  const session = await getSession();
  if (!session) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const res = await fetch(`${API_BASE}/trigger`, {
      headers: apiHeaders(),
      cache: "no-store",
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err) {
    return NextResponse.json({ error: String(err) }, { status: 502 });
  }
}
