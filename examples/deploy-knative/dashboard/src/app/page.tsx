'use client';

import { useEffect, useState, useCallback } from 'react';

interface AuditEvent {
  audit_id: string;
  action: string;
  asset_name: string;
  asset_id: string;
  timestamp: string;
  logged_at: string;
}

export default function DashboardPage() {
  const [auditLog, setAuditLog] = useState<AuditEvent[]>([]);
  const [podCount, setPodCount] = useState<number | null>(null);
  const [triggering, setTriggering] = useState(false);
  const [deploymentValid, setDeploymentValid] = useState(false);

  const fetchStatus = useCallback(() => {
    fetch('/api/knative-status')
      .then((r) => r.json())
      .then((data) => {
        setPodCount(data.pods ?? null);
        setDeploymentValid(data.healthy === true);
      })
      .catch(() => setPodCount(null));
  }, []);

  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 5000);
    return () => clearInterval(interval);
  }, [fetchStatus]);

  async function triggerAudit() {
    setTriggering(true);
    try {
      const res = await fetch('/api/audit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'create',
          asset_name: `test-server-${Date.now()}`,
          asset_id: `demo-${String(Math.floor(Math.random() * 9000) + 1000)}`,
          timestamp: new Date().toISOString(),
        }),
      });
      if (res.ok) {
        const data = await res.json();
        setAuditLog((prev) => [data, ...prev].slice(0, 20));
      }
    } catch {
      /* ignore */
    } finally {
      setTriggering(false);
      setTimeout(fetchStatus, 1000);
    }
  }

  const podColor = podCount === null ? '#8b949e' : podCount === 0 ? '#f0883e' : '#3fb950';
  const podLabel = podCount === null ? '...' : podCount === 0 ? '0 (scaled to zero)' : `${podCount} (active)`;

  const metricBoxStyle: React.CSSProperties = {
    background: '#0d1117', border: '1px solid #30363d', borderRadius: '8px', padding: '18px',
  };
  const labelStyle: React.CSSProperties = {
    fontSize: '11px', color: '#8b949e', textTransform: 'uppercase', letterSpacing: '1px', marginBottom: '6px',
  };
  const valueStyle: React.CSSProperties = { fontSize: '20px', fontWeight: 600, color: '#58a6ff' };
  const thStyle: React.CSSProperties = {
    padding: '10px 12px', textAlign: 'left', fontSize: '12px',
    color: '#94a3b8', borderBottom: '1px solid #334155',
  };
  const tdStyle: React.CSSProperties = {
    padding: '10px 12px', fontSize: '14px', borderBottom: '1px solid #1e293b',
  };

  return (
    <div style={{ maxWidth: '1100px', margin: '0 auto', padding: '48px 24px' }}>

      {/* Deployment Status */}
      <div style={{
        background: '#161b22', borderRadius: '12px', padding: '32px',
        marginBottom: '28px', border: '1px solid #30363d',
      }}>
        <span style={{
          display: 'inline-block', background: deploymentValid ? '#238636' : '#da3633',
          color: '#fff', padding: '6px 16px', borderRadius: '20px',
          fontSize: '13px', fontWeight: 600, letterSpacing: '0.5px', marginBottom: '20px',
        }}>
          {deploymentValid ? 'VALIDATED' : 'IN PROGRESS'}
        </span>
        <h2 style={{
          fontSize: '28px', fontWeight: 700, margin: '0 0 6px 0',
          background: 'linear-gradient(135deg, #58a6ff, #3fb950)',
          WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
        }}>
          VCF 9 Knative FaaS — AWS Lambda Equivalent
        </h2>
        <p style={{ color: '#8b949e', fontSize: '15px', margin: '0 0 28px 0' }}>
          Serverless audit function with scale-to-zero on Knative Serving
        </p>

        {/* 6 Metric Boxes — Row 1 */}
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '16px', marginBottom: '16px',
        }}>
          {[
            ['Compute', 'Knative Serving'],
            ['Networking', 'Contour'],
            ['DNS', 'sslip.io'],
          ].map(([label, value]) => (
            <div key={label as string} style={metricBoxStyle}>
              <div style={labelStyle}>{label as string}</div>
              <div style={valueStyle}>{value as string}</div>
            </div>
          ))}
        </div>

        {/* 6 Metric Boxes — Row 2 */}
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '16px', marginBottom: '28px',
        }}>
          <div style={metricBoxStyle}>
            <div style={labelStyle}>Audit Function</div>
            <div style={valueStyle}>asset-audit</div>
          </div>
          <div style={metricBoxStyle}>
            <div style={labelStyle}>Pod Status</div>
            <div style={{ ...valueStyle, color: podColor }}>{podLabel}</div>
          </div>
          <div style={metricBoxStyle}>
            <div style={labelStyle}>Dashboard</div>
            <div style={valueStyle}>Next.js</div>
          </div>
        </div>

        {/* Deployment Checklist */}
        <ul style={{ listStyle: 'none', padding: 0, margin: '0 0 24px 0' }}>
          {[
            'Knative Serving installed',
            'net-contour configured',
            'DNS configured (sslip.io)',
            'Audit function ready (asset-audit)',
          ].map((step) => (
            <li key={step} style={{
              padding: '11px 0', borderBottom: '1px solid #21262d',
              fontSize: '15px', display: 'flex', alignItems: 'center', gap: '10px',
            }}>
              <span style={{ color: deploymentValid ? '#3fb950' : '#8b949e', fontWeight: 'bold' }}>✓</span>
              {step}
            </li>
          ))}
        </ul>

        {/* AWS Lambda Equivalence Mapping */}
        <div style={{
          background: '#0d1117', border: '1px solid #30363d', borderRadius: '8px', padding: '20px',
        }}>
          <h3 style={{ fontSize: '14px', color: '#58a6ff', margin: '0 0 12px 0', fontWeight: 600 }}>
            AWS → VCF Knative Equivalence
          </h3>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px', fontSize: '13px' }}>
            {[
              ['Lambda', 'Knative Service'],
              ['API Gateway', 'Contour'],
              ['CloudWatch', 'kubectl logs'],
              ['DynamoDB Streams', 'HTTP webhook'],
            ].map(([aws, vcf]) => (
              <div key={aws} style={{ display: 'contents' }}>
                <span style={{ color: '#8b949e', padding: '4px 0' }}>{aws}</span>
                <span style={{ color: '#c9d1d9', padding: '4px 0' }}>→ {vcf}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Trigger Audit + Pod Count */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: '16px', marginBottom: '20px',
      }}>
        <button
          onClick={triggerAudit}
          disabled={triggering}
          style={{
            padding: '10px 24px', borderRadius: '6px', border: 'none',
            background: triggering ? '#484f58' : '#238636', color: '#fff',
            fontSize: '14px', fontWeight: 600, cursor: triggering ? 'default' : 'pointer',
          }}
        >
          {triggering ? 'Triggering...' : 'Trigger Audit'}
        </button>
        <span style={{ fontSize: '14px', color: '#8b949e' }}>
          Knative pods: <strong style={{ color: podColor }}>{podLabel}</strong>
        </span>
      </div>

      {/* Audit Log Table */}
      <div style={{ overflowX: 'auto', marginBottom: '40px' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', background: '#161b22', borderRadius: '12px' }}>
          <thead>
            <tr>
              <th style={thStyle}>Action</th>
              <th style={thStyle}>Asset Name</th>
              <th style={thStyle}>Asset ID</th>
              <th style={thStyle}>Timestamp</th>
            </tr>
          </thead>
          <tbody>
            {auditLog.map((e) => (
              <tr key={e.audit_id}>
                <td style={tdStyle}>
                  <span style={{
                    padding: '2px 10px', borderRadius: '9999px', fontSize: '12px',
                    background: e.action === 'create' ? '#166534' : e.action === 'delete' ? '#6e1b1b' : '#854d0e',
                    color: e.action === 'create' ? '#4ade80' : e.action === 'delete' ? '#f87171' : '#fbbf24',
                  }}>{e.action}</span>
                </td>
                <td style={tdStyle}>{e.asset_name}</td>
                <td style={tdStyle}>{e.asset_id}</td>
                <td style={tdStyle}>{e.timestamp ? new Date(e.timestamp).toLocaleString() : '—'}</td>
              </tr>
            ))}
            {auditLog.length === 0 && (
              <tr>
                <td colSpan={4} style={{ ...tdStyle, textAlign: 'center', color: '#64748b' }}>
                  No audit events yet — click &quot;Trigger Audit&quot; to generate one
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Footer */}
      <footer style={{ marginTop: '48px', textAlign: 'center', color: '#484f58', fontSize: '12px' }}>
        Powered by{' '}
        <a href="https://github.com/scafeman/vcf9-iac-onboarding" style={{ color: '#58a6ff', textDecoration: 'none' }}>
          vcf9-iac-onboarding
        </a>{' '}
        &middot; Knative Serving FaaS — Serverless Audit Function Demo
      </footer>
    </div>
  );
}
