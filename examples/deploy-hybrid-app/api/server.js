const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.API_PORT || 3001;

app.use(cors());
app.use(express.json());

// PostgreSQL connection pool
const poolConfig = {
  host: process.env.POSTGRES_HOST || 'localhost',
  port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
  user: process.env.POSTGRES_USER || 'assetadmin',
  password: process.env.POSTGRES_PASSWORD || 'assetpass',
  database: process.env.POSTGRES_DB || 'assetdb',
};

// Enable SSL for managed database connections (e.g., VCF DSM PostgresCluster)
if (process.env.POSTGRES_SSL === 'true' || process.env.POSTGRES_SSL === '1') {
  poolConfig.ssl = { rejectUnauthorized: false };
}

const pool = new Pool(poolConfig);

// ---------------------------------------------------------------------------
// Schema initialization and seed data
// ---------------------------------------------------------------------------

async function initializeSchema() {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS assets (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        ip_address TEXT,
        environment TEXT,
        notes TEXT,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        updated_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // Insert seed records only when the table is empty
    const countResult = await client.query('SELECT COUNT(*) FROM assets');
    const count = parseInt(countResult.rows[0].count, 10);

    if (count === 0) {
      const seedRecords = [
        { name: 'web-server-01', type: 'server', status: 'active', ip_address: '10.0.1.50', environment: 'production' },
        { name: 'db-cluster-01', type: 'database', status: 'active', ip_address: '10.0.2.10', environment: 'production' },
        { name: 'lb-frontend-01', type: 'load-balancer', status: 'active', ip_address: '10.0.0.100', environment: 'production' },
        { name: 'k8s-worker-03', type: 'server', status: 'maintenance', ip_address: '10.0.1.53', environment: 'staging' },
        { name: 'monitoring-01', type: 'server', status: 'active', ip_address: '10.0.3.20', environment: 'production' },
      ];

      for (const record of seedRecords) {
        await client.query(
          'INSERT INTO assets (name, type, status, ip_address, environment) VALUES ($1, $2, $3, $4, $5)',
          [record.name, record.type, record.status, record.ip_address, record.environment]
        );
      }

      console.log(`Seeded ${seedRecords.length} asset records`);
    } else {
      console.log(`Assets table already contains ${count} records, skipping seed`);
    }

    console.log('Schema initialization complete');
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

// Health check
app.get('/healthz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ status: 'ok', database: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', message: err.message });
  }
});

// List all assets
app.get('/api/assets', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM assets ORDER BY created_at DESC');
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve assets' });
  }
});

// Create a new asset
app.post('/api/assets', async (req, res) => {
  const { name, type, status, ip_address, environment, notes } = req.body;

  if (!name || !type || !status) {
    return res.status(400).json({ error: 'Missing required fields: name, type, status' });
  }

  try {
    const result = await pool.query(
      `INSERT INTO assets (name, type, status, ip_address, environment, notes)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
      [name, type, status, ip_address || null, environment || null, notes || null]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create asset' });
  }
});

// Update an asset by ID
app.put('/api/assets/:id', async (req, res) => {
  const { id } = req.params;
  const { name, type, status, ip_address, environment, notes } = req.body;

  if (!name || !type || !status) {
    return res.status(400).json({ error: 'Missing required fields: name, type, status' });
  }

  try {
    const result = await pool.query(
      `UPDATE assets SET name=$1, type=$2, status=$3, ip_address=$4, environment=$5, notes=$6, updated_at=NOW()
       WHERE id=$7 RETURNING *`,
      [name, type, status, ip_address || null, environment || null, notes || null, id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Asset not found' });
    }

    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update asset' });
  }
});

// Delete an asset by ID
app.delete('/api/assets/:id', async (req, res) => {
  const { id } = req.params;

  try {
    const result = await pool.query('DELETE FROM assets WHERE id=$1 RETURNING *', [id]);

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Asset not found' });
    }

    res.json({ message: 'Asset deleted', asset: result.rows[0] });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete asset' });
  }
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

initializeSchema()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`API server listening on port ${PORT}`);
    });
  })
  .catch((err) => {
    console.error('Schema initialization failed:', err.message);
    process.exit(1);
  });
