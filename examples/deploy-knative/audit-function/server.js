const express = require('express');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.PORT || 8080;

app.use(express.json());

// In-memory audit log
const auditLog = [];

// Health check
app.get('/', (_req, res) => {
  res.json({ status: 'ok' });
});

// Audit endpoint
app.post('/', (req, res) => {
  const { action, asset_name, asset_id, timestamp } = req.body;

  if (!action || !asset_name || !asset_id) {
    return res.status(400).json({
      error: 'Missing required fields: action, asset_name, asset_id',
    });
  }

  const entry = {
    status: 'logged',
    audit_id: uuidv4(),
    action,
    asset_name,
    asset_id,
    timestamp: timestamp || new Date().toISOString(),
    logged_at: new Date().toISOString(),
  };

  auditLog.push(entry);
  console.log(`Audit entry: ${JSON.stringify(entry)}`);
  res.json(entry);
});

// Retrieve audit log
app.get('/log', (_req, res) => {
  res.json(auditLog);
});

app.listen(PORT, () => {
  console.log(`Audit function listening on port ${PORT}`);
});
