require('dotenv').config();

// 1. Initialize Azure Monitor OpenTelemetry SDK
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  const { useAzureMonitor } = require("@azure/monitor-opentelemetry");
  useAzureMonitor();
  console.log("Azure Monitor Telemetry enabled on Frontend.");
} else {
  console.log("Running frontend locally without Azure Monitor Telemetry.");
}

const express = require('express');
const axios = require('axios');
const path = require('path');

const app = express();
const port = process.env.PORT || 8080;
const backendUrl = process.env.BACKEND_API_URL || "http://localhost:3000";

app.use(express.json());

// Serve static UI assets
app.use(express.static(path.join(__dirname, 'public')));

// Helper to extract authentication context from Easy Auth headers
function getAuthContext(req) {
  const principalName = req.headers['x-ms-client-principal-name'];
  const principalId = req.headers['x-ms-client-principal-id'];
  const accessToken = req.headers['x-ms-token-aad-access-token'];
  
  if (principalName) {
    return {
      authenticated: true,
      user: {
        name: principalName.split('@')[0],
        upn: principalName,
        oid: principalId
      },
      accessToken: accessToken
    };
  }

  // Fallback for local development
  return {
    authenticated: false,
    user: null,
    accessToken: null
  };
}

// 2. Health check route: Checks connection to Backend API
app.get('/status', async (req, res) => {
  const auth = getAuthContext(req);
  console.log("Frontend Status checked by:", auth.user ? auth.user.upn : "Anonymous/Local Dev");

  let backendHealth = null;
  try {
    const headers = {};
    if (auth.accessToken) {
      headers['Authorization'] = `Bearer ${auth.accessToken}`;
    }
    const response = await axios.get(`${backendUrl}/api/status`, { headers, timeout: 3000 });
    backendHealth = response.data;
  } catch (err) {
    console.error(`Backend connectivity check failed: ${err.message}`);
    backendHealth = { status: "Offline", error: err.message };
  }

  res.json({
    frontend: "Healthy",
    user: auth.user,
    backendHealth: backendHealth
  });
});

// 3. Proxy: Fetch items from Backend SQL Database
app.get('/data', async (req, res) => {
  const auth = getAuthContext(req);
  console.log(`Forwarding data request to backend. User: ${auth.user ? auth.user.upn : 'Local'}`);

  try {
    const headers = {};
    if (auth.accessToken) {
      headers['Authorization'] = `Bearer ${auth.accessToken}`;
    }
    const response = await axios.get(`${backendUrl}/api/data`, { headers });
    res.json(response.data);
  } catch (err) {
    const status = err.response ? err.response.status : 500;
    const errorData = err.response ? err.response.data : { error: err.message };
    console.error(`Error querying backend API: ${err.message}`);
    res.status(status).json(errorData);
  }
});

// 4. Proxy: Trigger error telemetry events
app.post('/trigger-error', async (req, res) => {
  const auth = getAuthContext(req);
  const { severity } = req.body;
  console.log(`Forwarding error simulation [${severity}] to backend. User: ${auth.user ? auth.user.upn : 'Local'}`);

  try {
    const headers = {};
    if (auth.accessToken) {
      headers['Authorization'] = `Bearer ${auth.accessToken}`;
    }
    const response = await axios.post(`${backendUrl}/api/trigger-error`, { severity }, { headers });
    res.json(response.data);
  } catch (err) {
    const status = err.response ? err.response.status : 500;
    const errorData = err.response ? err.response.data : { error: err.message };
    console.error(`Failed to forward warning/error to backend: ${err.message}`);
    res.status(status).json(errorData);
  }
});

app.listen(port, () => {
  console.log(`Governify Frontend Portal running on port ${port}`);
});
