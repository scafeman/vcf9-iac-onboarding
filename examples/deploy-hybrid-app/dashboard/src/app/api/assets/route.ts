import { NextRequest, NextResponse } from 'next/server';

const API_HOST = process.env.API_HOST || 'hybrid-app-api.hybrid-app.svc.cluster.local';
const API_PORT = process.env.API_PORT || '3001';
const BACKEND = `http://${API_HOST}:${API_PORT}`;

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const res = await fetch(`${BACKEND}/api/assets`, { cache: 'no-store' });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json({ error: 'Failed to reach API', detail: message }, { status: 502 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const res = await fetch(`${BACKEND}/api/assets`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json({ error: 'Failed to reach API', detail: message }, { status: 502 });
  }
}
