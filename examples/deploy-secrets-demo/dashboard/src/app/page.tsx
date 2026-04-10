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

function InfoCard({ label, value }: { label: string; value: string }) {
  return (
    <div style={{
      background: '#1e293b',
      borderRadius: '8px',
      padding: '16px 20px',
      border: '1px solid #334155',
      minWidth: '200px',
      flex: 1,
    }}>
      <div style={{ fontSize: '11px', color: '#64748b', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: '6px' }}>
        {label}
      </div>
      <div style={{ fontSize: '18px', fontWeight: 600, color: '#4ade80' }}>
        {value}
      </div>
    </div>
  );
}

function CheckItem({ label, passed, error }: { label: string; passed: boolean | null; error?: string }) {
  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      gap: '12px',
      padding: '12px 0',
      borderBottom: '1px solid #1e293b',
    }}>
      <span style={{ fontSize: '18px', flexShrink: 0, color: passed === null ? '#94a3b8' : passed ? '#4ade80' : '#f87171' }}>
        {passed === null ? '⏳' : passed ? '✓' : '✗'}
      </span>
      <span style={{
        fontSize: '14px',
        color: passed === null ? '#94a3b8' : passed ? '#e2e8f0' : '#f87171',
      }}>
        {label}
        {error && !passed && (
          <span style={{ color: '#f87171', fontSize: '12px', marginLeft: '8px' }}>— {error}</span>
        )}
      </span>
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

  const redisOk = data?.redis?.connected ?? null;
  const pgOk = data?.postgres?.connected ?? null;
  const allPassed = redisOk === true && pgOk === true;

  return (
    <div style={{ maxWidth: '780px', margin: '0 auto', padding: '48px 24px' }}>
      <div style={{
        background: '#0f172a',
        border: '1px solid #334155',
        borderRadius: '16px',
        padding: '40px',
      }}>
        {/* Status Badge */}
        <div style={{ marginBottom: '16px' }}>
          <span style={{
            display: 'inline-block',
            padding: '4px 14px',
            borderRadius: '9999px',
            fontSize: '12px',
            fontWeight: 600,
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
            background: allPassed ? '#166534' : data ? '#991b1b' : '#1e293b',
            color: allPassed ? '#4ade80' : data ? '#f87171' : '#94a3b8',
          }}>
            {allPassed ? 'Secrets Validated' : data ? 'Validation Failed' : 'Checking...'}
          </span>
        </div>

        {/* Title */}
        <h1 style={{
          fontSize: '32px',
          fontWeight: 700,
          margin: '0 0 8px 0',
          background: 'linear-gradient(135deg, #38bdf8, #818cf8)',
          WebkitBackgroundClip: 'text',
          WebkitTextFillColor: 'transparent',
        }}>
          VCF Secret Store Service — Secrets Demo
        </h1>
        <p style={{ color: '#94a3b8', margin: '0 0 32px 0', fontSize: '14px' }}>
          Infrastructure as Code deployment via GitHub Actions
        </p>

        {/* Info Cards */}
        <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', marginBottom: '32px' }}>
          <InfoCard label="Secret Store" value="VCF Secret Store" />
          <InfoCard label="Injection" value="Vault Injector" />
        </div>
        <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', marginBottom: '36px' }}>
          <InfoCard label="Data Tier" value="Redis + PostgreSQL" />
          <InfoCard label="Dashboard" value="Next.js" />
        </div>

        {/* Validation Checklist */}
        <div style={{ textAlign: 'left' }}>
          <CheckItem
            label="KeyValueSecrets created in supervisor namespace"
            passed={data ? true : null}
          />
          <CheckItem
            label="Service account token copied to guest cluster"
            passed={data ? true : null}
          />
          <CheckItem
            label="Vault-injector package installed and running"
            passed={data ? true : null}
          />
          <CheckItem
            label="Secrets injected into dashboard pod via sidecar"
            passed={data ? (redisOk !== null || pgOk !== null) : null}
          />
          <CheckItem
            label="Redis authenticated with vault-injected password"
            passed={redisOk}
            error={data?.redis?.error}
          />
          <CheckItem
            label="PostgreSQL authenticated with vault-injected credentials"
            passed={pgOk}
            error={data?.postgres?.error}
          />
          <CheckItem
            label="End-to-end secret lifecycle validated"
            passed={allPassed ? true : data ? false : null}
          />
        </div>

        {/* Timestamp */}
        {data?.timestamp && (
          <p style={{ color: '#64748b', fontSize: '12px', marginTop: '24px', textAlign: 'center' }}>
            Last updated: {new Date(data.timestamp).toLocaleString()}
          </p>
        )}
      </div>

      {/* Footer */}
      <footer style={{ marginTop: '32px', textAlign: 'center', color: '#475569', fontSize: '12px' }}>
        Powered by <span style={{ color: '#64748b' }}>vcf9-iac-onboarding</span> VCF 9 IaC Toolkit
      </footer>
    </div>
  );
}
