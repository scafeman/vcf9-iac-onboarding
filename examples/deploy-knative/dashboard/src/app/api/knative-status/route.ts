import { NextResponse } from 'next/server';
import { readFileSync } from 'fs';
import https from 'https';

export const dynamic = 'force-dynamic';

const K8S_TOKEN_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/token';
const K8S_CA_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt';
const K8S_NS_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/namespace';

async function getPodCount(): Promise<number> {
  try {
    const token = readFileSync(K8S_TOKEN_PATH, 'utf-8').trim();
    const ca = readFileSync(K8S_CA_PATH);
    const namespace = process.env.DEMO_NAMESPACE || readFileSync(K8S_NS_PATH, 'utf-8').trim();

    const url = `https://kubernetes.default.svc/api/v1/namespaces/${namespace}/pods?labelSelector=serving.knative.dev/service=asset-audit`;

    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
      // @ts-expect-error — Node fetch supports agent-like TLS options
      agent: new https.Agent({ ca }),
      cache: 'no-store',
    });

    if (!res.ok) return 0;
    const data = await res.json();
    const running = (data.items || []).filter(
      (p: { status?: { phase?: string } }) => p.status?.phase === 'Running',
    );
    return running.length;
  } catch {
    // Fallback: if not running in-cluster, return -1 to indicate unknown
    return -1;
  }
}

export async function GET() {
  const pods = await getPodCount();
  return NextResponse.json({ pods, healthy: pods >= 0 });
}
