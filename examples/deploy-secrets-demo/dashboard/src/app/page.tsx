'use client';

import { useEffect, useState } from 'react';

interface ServiceStatus {
  connected: boolean;
  error?: string;
}

interface StatusResponse {
  redis: ServiceStatus;
  postgres: ServiceStatus;
  timestamp: string;
}

function StatusCard({ name, status }: { name: string; status: ServiceStatus | null }) {
  const isLoading = status === null;
  const connected = status?.connected ?? false;

  return (
    <div style={{
      background: '#1e293b',
      borderRadius: '12px',
      padding: '24px',
      minWidth: '280px',
      border: `1px solid ${connected ? '#22c55e33' : '#ef444433'}`,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px', marginBottom: '12px' }}>
        <span style={{ fontSize: '32px' }}>
          {isLoading ? '⏳' : connected ? '✅' : '❌'}
        </span>
        <h2 style={{ margin: 0, fontSize: '20px', color: '#f8fafc' }}>{name}</h2>
      </div>
      <p style={{
        margin: 0,
        fontSize: '14px',
        color: isLoading ? '#94a3b8' : connected ? '#4ade80' : '#f87171',
      }}>
        {isLoading ? 'Checking...' : connected ? 'Connected' : status?.error || 'Connection failed'}
      </p>
    </div>
  );
}

export default function DashboardPage() {
  const [data, setData] = useState<StatusResponse | null>(null);

  useEffect(() => {
    const fetchStatus = () => {
      fetch('/api/status')
        .then((res) => res.json())
        .then((json) => setData(json))
        .catch(() => {});
    };

    fetchStatus();
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, []);

  return (
    <div style={{ maxWidth: '720px', margin: '0 auto', padding: '48px 24px', textAlign: 'center' }}>
      <h1 style={{
        fontSize: '36px',
        fontWeight: 700,
        margin: '0 0 8px 0',
        background: 'linear-gradient(135deg, #38bdf8, #818cf8)',
        WebkitBackgroundClip: 'text',
        WebkitTextFillColor: 'transparent',
      }}>
        VCF Secrets Demo
      </h1>
      <p style={{ color: '#94a3b8', margin: '0 0 40px 0', fontSize: '14px' }}>
        VCF Secret Store Service → Vault Injector → Application
      </p>

      <div style={{ display: 'flex', gap: '20px', justifyContent: 'center', flexWrap: 'wrap' }}>
        <StatusCard name="Redis" status={data?.redis ?? null} />
        <StatusCard name="PostgreSQL" status={data?.postgres ?? null} />
      </div>

      {data?.timestamp && (
        <p style={{ color: '#64748b', fontSize: '12px', marginTop: '32px' }}>
          Last updated: {new Date(data.timestamp).toLocaleString()}
        </p>
      )}

      <footer style={{ marginTop: '48px', color: '#475569', fontSize: '12px' }}>
        Powered by VCF Secret Store Service — The VCF equivalent of AWS Secrets Manager
      </footer>
    </div>
  );
}
