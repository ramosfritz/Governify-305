require('dotenv').config();

// 1. Initialize Azure Monitor OpenTelemetry SDK
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  const { useAzureMonitor } = require("@azure/monitor-opentelemetry");
  useAzureMonitor();
  console.log("Azure Monitor Telemetry enabled.");
} else {
  console.log("Running locally without Azure Monitor Telemetry.");
}

const express = require('express');
const jwt = require('jsonwebtoken');
const jwksRsa = require('jwks-rsa');
const sql = require('mssql');

const app = express();
const port = process.env.PORT || 3000;

app.use(express.json());

// Enable CORS
app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept, Authorization");
  next();
});

// 2. Azure AD Token Validation Middleware
const validateToken = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    console.warn("Unauthenticated request blocked (Missing/Malformed Auth Header)");
    return res.status(401).json({ error: "Unauthorized: Missing Bearer Token" });
  }

  const token = authHeader.split(' ')[1];
  const tenantId = process.env.TENANT_ID || 'common';
  
  // Configure JWKS client to fetch Microsoft public keys
  const client = jwksRsa({
    jwksUri: `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`,
    cache: true,
    rateLimit: true
  });

  function getKey(header, callback){
    client.getSigningKey(header.kid, function(err, key) {
      if (err) {
        callback(err);
      } else {
        const signingKey = key.getPublicKey();
        callback(null, signingKey);
      }
    });
  }

  const options = {
    audience: process.env.CLIENT_ID || process.env.AUDIENCE,
    issuer: `https://sts.windows.net/${tenantId}/`
  };

  // If running in development and vars aren't set, allow skipping verification for easy debugging
  if (process.env.NODE_ENV === 'development' && !process.env.CLIENT_ID) {
    console.log("Development Mode: Bypassing token validation because CLIENT_ID is not configured");
    req.user = { name: "Local Dev User", upn: "dev@localhost" };
    return next();
  }

  jwt.verify(token, getKey, options, (err, decoded) => {
    if (err) {
      console.error(`Token validation failed: ${err.message}`);
      return res.status(403).json({ error: `Forbidden: Invalid Token. Details: ${err.message}` });
    }
    req.user = decoded;
    console.log(`Successfully authenticated request for user: ${decoded.upn || decoded.name}`);
    next();
  });
};

// 3. SQL Database Connection setup
let dbPool = null;
async function getDbConnection() {
  if (dbPool) return dbPool;

  const connStr = process.env.SQL_CONNECTION_STRING;
  if (!connStr) {
    console.log("SQL_CONNECTION_STRING is not set. Database features will run in mock mode.");
    return null;
  }

  try {
    dbPool = await sql.connect(connStr);
    console.log("Connected to Azure SQL Database successfully.");
    return dbPool;
  } catch (err) {
    console.error("Failed to connect to Azure SQL Database:", err.message);
    dbPool = null;
    throw err;
  }
}

// 4. API Endpoints
// Status Check (No Authentication Required)
app.get('/api/status', async (req, res) => {
  console.log("Status endpoint called.");
  let dbStatus = "Disconnected";
  try {
    const pool = await getDbConnection();
    dbStatus = pool ? "Connected" : "Mock Mode (No connection string)";
  } catch (err) {
    dbStatus = `Error: ${err.message}`;
  }

  res.json({
    status: "Healthy",
    time: new Date(),
    environment: process.env.NODE_ENV || "production",
    database: dbStatus
  });
});

// Secured Data Retrieval (Authentication Required)
app.get('/api/data', validateToken, async (req, res) => {
  console.log(`Data endpoint requested by ${req.user.upn || req.user.name}`);
  try {
    const pool = await getDbConnection();
    if (!pool) {
      // Mock data in absence of real Azure SQL
      return res.json([
        { id: 1, name: "Sample Item A", category: "Mock" },
        { id: 2, name: "Sample Item B", category: "Mock" }
      ]);
    }
    const result = await pool.request().query('SELECT TOP 10 * FROM Items');
    res.json(result.recordset);
  } catch (err) {
    console.error("SQL query failed:", err.message);
    res.status(500).json({ error: "Failed to query database", details: err.message });
  }
});

// Diagnostics & Alerts Trigger Endpoint
app.post('/api/trigger-error', validateToken, (req, res) => {
  const { severity } = req.body;
  const user = req.user.upn || req.user.name;

  if (severity === 'critical') {
    console.error(`CRITICAL: Simulated critical failure triggered by user: ${user}`);
    res.status(500).json({ status: "Simulated Critical Error Logged" });
  } else {
    console.warn(`WARNING: Simulated warning triggered by user: ${user}`);
    res.json({ status: "Simulated Warning Logged" });
  }
});

app.listen(port, () => {
  console.log(`Governify Backend API running on port ${port}`);
});
