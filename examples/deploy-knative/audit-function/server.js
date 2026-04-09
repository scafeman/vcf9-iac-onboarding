const express = require('express');
const { Pool } = require('pg');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.PORT || 8080;

app.use(express.json());

// ---------------------------------------------------------------------------
// PostgreSQL connection pool
// ---------------------------------------------------------------------------

const poolConfig = {
  host: process.env.POSTGRES_HOST || 'localhost',
  port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
  user: process.env.POSTGRES_USER || 'pgadmin',
  password: process.env.POSTGRES_PASSWORD || '',
  database: process.env.POSTGRES_DB || 'assetdb',
};

// Enable SSL for DSM PostgresCluster connections
if (process.env.POSTGRES_SSL === 'true' || process.env.POSTGRES_SSL === '1') {
  poolConfig.ssl = { rejectUnauthorized: false };
}

const pool = new Pool(poolConfig);

// ---------------------------------------------------------------------------
// Schema initialization — create audit_log table if it doesn't exist
// (handles cold start after scale-to-zero)
// ---------------------------------------------------------------------------

async function initializeSchema() {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS audit_log (
        audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        action TEXT NOT NULL,
        asset_name TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        timestamp TIMESTAMPTZ,
        logged_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
    console.log('Audit function schema initialization complete');
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

// Health check
app.get('/', (_req, res) => {
  res.json({ status: 'ok' });
});

// Audit endpoint — insert audit entry into audit_log table
app.post('/', async (req, res) => {
  const { action, asset_name, asset_id, timestamp } = req.body;

  if (!action || !asset_name || !asset_id) {
    return res.status(400).json({
      error: 'Missing required fields: action, asset_name, asset_id',
    });
  }

  try {
    const ts = timestamp || new Date().toISOString();
    const result = await pool.query(
      `INSERT INTO audit_log (action, asset_name, asset_id, timestamp)
       VALUES ($1, $2, $3, $4) RETURNING *`,
      [action, asset_name, asset_id, ts]
    );

    const entry = result.rows[0];
    const response = {
      status: 'logged',
      audit_id: entry.audit_id,
      action: entry.action,
      asset_name: entry.asset_name,
      asset_id: entry.asset_id,
      timestamp: entry.timestamp,
      logged_at: entry.logged_at,
    };

    console.log(`Audit entry: ${JSON.stringify(response)}`);
    res.json(response);
  } catch (err) {
    console.error('Failed to insert audit entry:', err.message);
    res.status(500).json({ error: 'Failed to write audit entry', details: err.message });
  }
});

// Retrieve audit log — ordered by logged_at DESC, limit 100
app.get('/log', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM audit_log ORDER BY logged_at DESC LIMIT 100'
    );
    res.json(result.rows);
  } catch (err) {
    console.error('Failed to retrieve audit log:', err.message);
    res.status(500).json({ error: 'Failed to retrieve audit log', details: err.message });
  }
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

initializeSchema()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`Audit function listening on port ${PORT}`);
    });
  })
  .catch((err) => {
    console.error('Schema initialization failed:', err.message);
    process.exit(1);
  });
