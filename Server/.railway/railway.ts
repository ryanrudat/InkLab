import { defineRailway, project, service } from "railway/iac";

// Railway infrastructure for the InkLab proxy (replaces the retired railway.json "Config as Code").
// Variables (API keys, the app secret) are NOT managed here: they stay in the Railway dashboard.
// Preview with `railway config plan`, apply with `railway config apply`.
export default defineRailway(() => {
  const inklabProxy = service("inklab-proxy", {
    build: { buildEnvironment: "V3", builder: "RAILPACK" },
    deploy: {
      startCommand: "node --env-file-if-exists=.env src/server.ts",
      healthcheckPath: "/health",
      healthcheckTimeout: 30,
      // Restart policy: Railway's default (restart on failure, up to 10 times) is what we want, and Railway
      // stores the default as "unset", so setting it here would show up as a change on every plan.
    },
    replicas: { "us-west2": 1 },
  });

  return project("inklab-proxy", {
    variables: { managed: false },
    resources: [inklabProxy],
  });
});
