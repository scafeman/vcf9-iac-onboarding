import { NextResponse } from 'next/server';

const API_HOST = process.env.API_HOST || 'managed-db-api.managed-db-app.svc.cluster.local';
const API_PORT = process.env.API_PORT || '3001';
const BACKEND = `http://${API_HOST}:${API_PORT}`;

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const res = await fetch(`${BACKEND}/healthz`, { cache: 'no-store' });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json({ status: 'error', database: 'unreachable', detail: message }, { status: 502 });
  }
}
