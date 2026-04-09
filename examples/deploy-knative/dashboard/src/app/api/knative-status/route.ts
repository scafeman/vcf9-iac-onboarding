import { NextResponse } from 'next/server';

export const dynamic = 'force-dynamic';

const API_HOST = process.env.API_HOST || 'http://knative-api-server.knative-demo.svc.cluster.local:3001';
const BACKEND = API_HOST.startsWith('http') ? API_HOST : `http://${API_HOST}`;

export async function GET() {
  // Check if the API server is healthy (proves the full stack is working)
  let apiHealthy = false;
  try {
    const res = await fetch(`${BACKEND}/healthz`, { cache: 'no-store' });
    if (res.ok) {
      const data = await res.json();
      apiHealthy = data.status === 'ok' && data.database === 'connected';
    }
  } catch {
    apiHealthy = false;
  }

  // Try to get pod count from Kubernetes API using service account
  let pods = 0;
  try {
    const fs = await import('fs');
    const tokenPath = '/var/run/secrets/kubernetes.io/serviceaccount/token';
    if (fs.existsSync(tokenPath)) {
      const token = fs.readFileSync(tokenPath, 'utf-8').trim();
      const ns = process.env.DEMO_NAMESPACE || 'knative-demo';
      const url = `https://kubernetes.default.svc/api/v1/namespaces/${ns}/pods?labelSelector=serving.knative.dev/service=asset-audit`;

      // Temporarily disable TLS verification for in-cluster API
      const origTLS = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${token}` },
        cache: 'no-store',
      });
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = origTLS || '1';

      if (res.ok) {
        const data = await res.json();
        pods = (data.items || []).filter(
          (p: { status?: { phase?: string } }) => p.status?.phase === 'Running',
        ).length;
      }
    }
  } catch {
    pods = 0;
  }

  return NextResponse.json({ pods, healthy: apiHealthy });
}
