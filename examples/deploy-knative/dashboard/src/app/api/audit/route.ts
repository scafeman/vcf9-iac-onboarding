import { NextResponse } from 'next/server';

const AUDIT_HOST = process.env.AUDIT_HOST || 'http://asset-audit.knative-demo.svc.cluster.local';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const res = await fetch(`${AUDIT_HOST}/log`, { cache: 'no-store' });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json(
      { status: 'error', detail: message },
      { status: 502 },
    );
  }
}

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const res = await fetch(AUDIT_HOST, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      cache: 'no-store',
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json(
      { status: 'error', detail: message },
      { status: 502 },
    );
  }
}
