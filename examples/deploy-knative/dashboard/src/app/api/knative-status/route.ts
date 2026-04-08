import { NextResponse } from 'next/server';
import { execSync } from 'child_process';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const output = execSync(
      'kubectl get pods -n knative-demo -l serving.knative.dev/service=asset-audit --no-headers 2>/dev/null | grep -c Running || echo 0',
      { timeout: 5000, encoding: 'utf-8' },
    ).trim();
    const pods = parseInt(output, 10) || 0;
    return NextResponse.json({ pods, healthy: true });
  } catch {
    return NextResponse.json({ pods: 0, healthy: false });
  }
}
