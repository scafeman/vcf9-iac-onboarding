'use client';

import { useEffect, useState, useCallback } from 'react';

interface Asset {
  id: string;
  name: string;
  type: string;
  status: string;
  ip_address: string | null;
  environment: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

interface AuditEvent {
  audit_id: string;
  action: string;
  asset_name: string;
  asset_id: string;
  timestamp: string;
  logged_at: string;
}

type SortField = 'name' | 'type' | 'status' | 'ip_address' | 'environment' | 'updated_at';
type SortDir = 'asc' | 'desc';

const emptyForm = { name: '', type: '', status: '', ip_address: '', environment: '', notes: '' };

export default function DashboardPage() {
  const [assets, setAssets] = useState<Asset[]>([]);
  const [auditLog, setAuditLog] = useState<AuditEvent[]>([]);
  const [podCount, setPodCount] = useState<number | null>(null);
  const [deploymentValid, setDeploymentValid] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [editAsset, setEditAsset] = useState<Asset | null>(null);
  const [editForm, setEditForm] = useState(emptyForm);
  const [editErrors, setEditErrors] = useState<Record<string, string>>({});
  const [deleteTarget, setDeleteTarget] = useState<Asset | null>(null);
  const [filter, setFilter] = useState('');
  const [sortField, setSortField] = useState<SortField>('updated_at');
  const [sortDir, setSortDir] = useState<SortDir>('desc');

  const fetchAssets = useCallback(() => {
    fetch('/api/assets')
      .then((r) => r.json())
      .then((data) => { if (Array.isArray(data)) setAssets(data); })
      .catch(() => {});
  }, []);

  const fetchAuditLog = useCallback(() => {
    fetch('/api/audit')
      .then((r) => r.json())
      .then((data) => { if (Array.isArray(data)) setAuditLog(data); })
      .catch(() => {});
  }, []);

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
    fetchAssets();
    fetchAuditLog();
    fetchStatus();
    const interval = setInterval(() => {
      fetchAssets(); fetchAuditLog(); fetchStatus();
    }, 5000);
    return () => clearInterval(interval);
  }, [fetchAssets, fetchAuditLog, fetchStatus]);

  /* ---- refresh helpers ---- */
  function refreshAll() {
    fetchAssets();
    fetchAuditLog();
    setTimeout(fetchAuditLog, 1000);
    setTimeout(fetchStatus, 500);
    setTimeout(fetchStatus, 2000);
  }

  /* ---- validation ---- */
  function validate(f: typeof emptyForm): Record<string, string> {
    const e: Record<string, string> = {};
    if (!f.name.trim()) e.name = 'Name is required';
    if (!f.type.trim()) e.type = 'Type is required';
    if (!f.status.trim()) e.status = 'Status is required';
    return e;
  }

  /* ---- create ---- */
  function handleCreate() {
    const v = validate(form);
    setErrors(v);
    if (Object.keys(v).length) return;
    fetch('/api/assets', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(form),
    })
      .then((r) => { if (r.ok) { setForm(emptyForm); refreshAll(); } })
      .catch(() => {});
  }

  /* ---- edit ---- */
  function openEdit(a: Asset) {
    setEditAsset(a);
    setEditForm({
      name: a.name, type: a.type, status: a.status,
      ip_address: a.ip_address || '', environment: a.environment || '', notes: a.notes || '',
    });
    setEditErrors({});
  }

  function handleUpdate() {
    if (!editAsset) return;
    const v = validate(editForm);
    setEditErrors(v);
    if (Object.keys(v).length) return;
    fetch(`/api/assets/${editAsset.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(editForm),
    })
      .then((r) => { if (r.ok) { setEditAsset(null); refreshAll(); } })
      .catch(() => {});
  }

  /* ---- delete ---- */
  function handleDelete() {
    if (!deleteTarget) return;
    fetch(`/api/assets/${deleteTarget.id}`, { method: 'DELETE' })
      .then((r) => { if (r.ok) { setDeleteTarget(null); refreshAll(); } })
      .catch(() => {});
  }

  /* ---- sort & filter ---- */
  function toggleSort(field: SortField) {
    if (sortField === field) setSortDir(sortDir === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDir('asc'); }
  }

  const filtered = assets
    .filter((a) => {
      const q = filter.toLowerCase();
      return !q || a.name.toLowerCase().includes(q) || a.type.toLowerCase().includes(q)
        || a.status.toLowerCase().includes(q) || (a.ip_address || '').toLowerCase().includes(q)
        || (a.environment || '').toLowerCase().includes(q);
    })
    .sort((a, b) => {
      const av = (a[sortField] ?? '') as string;
      const bv = (b[sortField] ?? '') as string;
      const cmp = av.localeCompare(bv);
      return sortDir === 'asc' ? cmp : -cmp;
    });

  const podColor = podCount === null ? '#8b949e' : podCount === 0 ? '#f0883e' : '#3fb950';
  const podLabel = podCount === null ? '...' : podCount === 0 ? '0 (scaled to zero)' : `${podCount} (active)`;

  /* ---- shared styles ---- */
  const metricBoxStyle: React.CSSProperties = {
    background: '#0d1117', border: '1px solid #30363d', borderRadius: '8px', padding: '18px',
  };
  const labelStyle: React.CSSProperties = {
    fontSize: '11px', color: '#8b949e', textTransform: 'uppercase', letterSpacing: '1px', marginBottom: '6px',
  };
  const valueStyle: React.CSSProperties = { fontSize: '20px', fontWeight: 600, color: '#58a6ff' };
  const inputStyle: React.CSSProperties = {
    padding: '8px 12px', borderRadius: '6px', border: '1px solid #334155',
    background: '#0f172a', color: '#e2e8f0', fontSize: '14px', width: '100%', boxSizing: 'border-box',
  };
  const btnPrimary: React.CSSProperties = {
    padding: '8px 20px', borderRadius: '6px', border: 'none',
    background: '#238636', color: '#fff', fontSize: '14px', cursor: 'pointer',
  };
  const btnDanger: React.CSSProperties = {
    padding: '6px 14px', borderRadius: '6px', border: 'none',
    background: '#ef4444', color: '#fff', fontSize: '13px', cursor: 'pointer',
  };
  const btnSecondary: React.CSSProperties = {
    padding: '6px 14px', borderRadius: '6px', border: '1px solid #475569',
    background: 'transparent', color: '#94a3b8', fontSize: '13px', cursor: 'pointer',
  };
  const thStyle: React.CSSProperties = {
    padding: '10px 12px', textAlign: 'left', fontSize: '12px',
    color: '#94a3b8', borderBottom: '1px solid #334155', cursor: 'pointer', userSelect: 'none',
  };
  const tdStyle: React.CSSProperties = {
    padding: '10px 12px', fontSize: '14px', borderBottom: '1px solid #1e293b',
  };
  const overlayStyle: React.CSSProperties = {
    position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.6)',
    display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100,
  };
  const modalStyle: React.CSSProperties = {
    background: '#1e293b', borderRadius: '12px', padding: '28px',
    width: '100%', maxWidth: '480px', border: '1px solid #334155',
  };
  const errStyle: React.CSSProperties = { color: '#f87171', fontSize: '12px', marginTop: '2px' };

  function renderField(
    label: string, value: string,
    onChange: (v: string) => void, error?: string, placeholder?: string,
  ) {
    return (
      <div style={{ marginBottom: '12px' }}>
        <label style={{ fontSize: '12px', color: '#94a3b8', marginBottom: '4px', display: 'block' }}>{label}</label>
        <input style={inputStyle} value={value} placeholder={placeholder || label}
          onChange={(e) => onChange(e.target.value)} />
        {error && <div style={errStyle}>{error}</div>}
      </div>
    );
  }

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
          VCF 9 Knative FaaS + DBaaS — AWS Lambda + RDS Equivalent
        </h2>
        <p style={{ color: '#8b949e', fontSize: '15px', margin: '0 0 28px 0' }}>
          Asset Tracker with DSM PostgreSQL, serverless audit function, and scale-to-zero on Knative Serving
        </p>

        {/* 6 Metric Boxes — Row 1 */}
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '16px', marginBottom: '16px',
        }}>
          {[
            ['Compute', 'Knative Serving'],
            ['Database', 'DSM PostgresCluster'],
            ['Networking', 'Contour'],
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
            <div style={labelStyle}>DNS</div>
            <div style={valueStyle}>sslip.io</div>
          </div>
          <div style={metricBoxStyle}>
            <div style={labelStyle}>Audit Function</div>
            <div style={valueStyle}>asset-audit</div>
          </div>
          <div style={metricBoxStyle}>
            <div style={labelStyle}>Pod Status</div>
            <div style={{ ...valueStyle, color: podColor }}>{podLabel}</div>
          </div>
        </div>

        {/* Deployment Checklist */}
        <ul style={{ listStyle: 'none', padding: 0, margin: '0 0 24px 0' }}>
          {[
            'Knative Serving installed',
            'net-contour configured',
            'DNS configured (sslip.io)',
            'DSM PostgresCluster provisioned',
            'API server deployed',
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

        {/* AWS Equivalence Mapping */}
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
              ['RDS PostgreSQL', 'DSM PostgresCluster'],
              ['DynamoDB Streams', 'HTTP webhook'],
              ['CloudWatch', 'kubectl logs'],
            ].map(([aws, vcf]) => (
              <div key={aws} style={{ display: 'contents' }}>
                <span style={{ color: '#8b949e', padding: '4px 0' }}>{aws}</span>
                <span style={{ color: '#c9d1d9', padding: '4px 0' }}>→ {vcf}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Asset Tracker Heading */}
      <div style={{ textAlign: 'center', marginBottom: '24px' }}>
        <h1 style={{
          fontSize: '36px', fontWeight: 700, margin: '0',
          background: 'linear-gradient(135deg, #38bdf8, #818cf8)',
          WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
        }}>
          VCF Infrastructure Asset Tracker
        </h1>
      </div>

      {/* Create Form */}
      <div style={{
        background: '#1e293b', borderRadius: '12px', padding: '24px',
        marginBottom: '28px', border: '1px solid #334155',
      }}>
        <h2 style={{ margin: '0 0 16px 0', fontSize: '18px', color: '#f8fafc' }}>Add Asset</h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))', gap: '12px' }}>
          {renderField('Name *', form.name, (v) => setForm({ ...form, name: v }), errors.name)}
          {renderField('Type *', form.type, (v) => setForm({ ...form, type: v }), errors.type, 'e.g. server')}
          {renderField('Status *', form.status, (v) => setForm({ ...form, status: v }), errors.status, 'e.g. active')}
          {renderField('IP Address', form.ip_address, (v) => setForm({ ...form, ip_address: v }), undefined, '10.0.1.50')}
          {renderField('Environment', form.environment, (v) => setForm({ ...form, environment: v }), undefined, 'production')}
          {renderField('Notes', form.notes, (v) => setForm({ ...form, notes: v }))}
        </div>
        <div style={{ marginTop: '12px' }}>
          <button style={btnPrimary} onClick={handleCreate}>Create Asset</button>
        </div>
      </div>

      {/* Filter */}
      <div style={{ marginBottom: '16px' }}>
        <input style={{ ...inputStyle, maxWidth: '320px' }} placeholder="Filter assets..."
          value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>

      {/* Asset Table */}
      <div style={{ overflowX: 'auto', marginBottom: '40px' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', background: '#1e293b', borderRadius: '12px' }}>
          <thead>
            <tr>
              {([
                ['name', 'Name'], ['type', 'Type'], ['status', 'Status'],
                ['ip_address', 'IP Address'], ['environment', 'Environment'], ['updated_at', 'Updated'],
              ] as [SortField, string][]).map(([f, label]) => (
                <th key={f} style={thStyle} onClick={() => toggleSort(f)}>
                  {label} {sortField === f ? (sortDir === 'asc' ? '▲' : '▼') : ''}
                </th>
              ))}
              <th style={{ ...thStyle, cursor: 'default' }}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((a) => (
              <tr key={a.id}>
                <td style={tdStyle}>{a.name}</td>
                <td style={tdStyle}>{a.type}</td>
                <td style={tdStyle}>
                  <span style={{
                    padding: '2px 10px', borderRadius: '9999px', fontSize: '12px',
                    background: a.status === 'active' ? '#166534' : a.status === 'maintenance' ? '#854d0e' : '#1e293b',
                    color: a.status === 'active' ? '#4ade80' : a.status === 'maintenance' ? '#fbbf24' : '#94a3b8',
                  }}>{a.status}</span>
                </td>
                <td style={tdStyle}>{a.ip_address || '—'}</td>
                <td style={tdStyle}>{a.environment || '—'}</td>
                <td style={tdStyle}>{a.updated_at ? new Date(a.updated_at).toLocaleString() : '—'}</td>
                <td style={tdStyle}>
                  <div style={{ display: 'flex', gap: '6px' }}>
                    <button style={btnSecondary} onClick={() => openEdit(a)}>Edit</button>
                    <button style={btnDanger} onClick={() => setDeleteTarget(a)}>Delete</button>
                  </div>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ ...tdStyle, textAlign: 'center', color: '#64748b' }}>No assets found</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Audit Trail Section */}
      <div style={{ marginBottom: '40px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px', marginBottom: '16px' }}>
          <h2 style={{ margin: 0, fontSize: '22px', color: '#f8fafc' }}>Audit Trail</h2>
          <span style={{ fontSize: '14px', color: '#8b949e' }}>
            Knative pods: <strong style={{ color: podColor }}>{podLabel}</strong>
          </span>
        </div>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', background: '#161b22', borderRadius: '12px' }}>
            <thead>
              <tr>
                <th style={{ ...thStyle, cursor: 'default' }}>Action</th>
                <th style={{ ...thStyle, cursor: 'default' }}>Asset Name</th>
                <th style={{ ...thStyle, cursor: 'default' }}>Asset ID</th>
                <th style={{ ...thStyle, cursor: 'default' }}>Timestamp</th>
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
                    No audit events yet — create, update, or delete an asset to generate audit entries
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Edit Modal */}
      {editAsset && (
        <div style={overlayStyle} onClick={() => setEditAsset(null)}>
          <div style={modalStyle} onClick={(e) => e.stopPropagation()}>
            <h2 style={{ margin: '0 0 16px 0', fontSize: '18px', color: '#f8fafc' }}>Edit Asset</h2>
            {renderField('Name *', editForm.name, (v) => setEditForm({ ...editForm, name: v }), editErrors.name)}
            {renderField('Type *', editForm.type, (v) => setEditForm({ ...editForm, type: v }), editErrors.type)}
            {renderField('Status *', editForm.status, (v) => setEditForm({ ...editForm, status: v }), editErrors.status)}
            {renderField('IP Address', editForm.ip_address, (v) => setEditForm({ ...editForm, ip_address: v }))}
            {renderField('Environment', editForm.environment, (v) => setEditForm({ ...editForm, environment: v }))}
            {renderField('Notes', editForm.notes, (v) => setEditForm({ ...editForm, notes: v }))}
            <div style={{ display: 'flex', gap: '10px', marginTop: '16px' }}>
              <button style={btnPrimary} onClick={handleUpdate}>Save</button>
              <button style={btnSecondary} onClick={() => setEditAsset(null)}>Cancel</button>
            </div>
          </div>
        </div>
      )}

      {/* Delete Confirmation */}
      {deleteTarget && (
        <div style={overlayStyle} onClick={() => setDeleteTarget(null)}>
          <div style={modalStyle} onClick={(e) => e.stopPropagation()}>
            <h2 style={{ margin: '0 0 12px 0', fontSize: '18px', color: '#f8fafc' }}>Confirm Delete</h2>
            <p style={{ color: '#94a3b8', margin: '0 0 20px 0' }}>
              Are you sure you want to delete <strong style={{ color: '#e2e8f0' }}>{deleteTarget.name}</strong>?
            </p>
            <div style={{ display: 'flex', gap: '10px' }}>
              <button style={btnDanger} onClick={handleDelete}>Delete</button>
              <button style={btnSecondary} onClick={() => setDeleteTarget(null)}>Cancel</button>
            </div>
          </div>
        </div>
      )}

      {/* Footer */}
      <footer style={{ marginTop: '48px', textAlign: 'center', color: '#484f58', fontSize: '12px' }}>
        Powered by{' '}
        <a href="https://github.com/scafeman/vcf9-iac-onboarding" style={{ color: '#58a6ff', textDecoration: 'none' }}>
          vcf9-iac-onboarding
        </a>{' '}
        &middot; Knative FaaS + DSM DBaaS — Asset Tracker with Serverless Audit
      </footer>
    </div>
  );
}
