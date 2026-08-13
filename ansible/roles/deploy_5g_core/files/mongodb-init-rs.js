// Idempotent single-member rs0 init. Keep in sync with
// packages/blueprints/mongodb-init/job.yaml (mongodb-init-rs.js).
//
// Member host MUST match mongod's hostname (the StatefulSet pod FQDN).
// Using the Service name "mongodb:27017" leaves InvalidReplicaSetConfig after
// a rebuild/PVC reuse because the process identity is
// mongodb-0.mongodb.<ns>.svc.cluster.local.
const desiredHost = 'mongodb-0.mongodb.5g-core.svc.cluster.local:27017';

function desiredConfig(version) {
  return {
    _id: 'rs0',
    version: version,
    members: [{ _id: 0, host: desiredHost, priority: 1 }]
  };
}

function currentConfig() {
  try { return rs.conf(); } catch (e) { return null; }
}

function isPrimary() {
  try {
    const status = rs.status();
    return status.ok === 1 && (status.members || []).some(function (m) {
      return m.stateStr === 'PRIMARY' && m.health === 1;
    });
  } catch (e) {
    return false;
  }
}

function memberHost(conf) {
  try { return conf.members[0].host; } catch (e) { return ''; }
}

const conf = currentConfig();
if (isPrimary() && memberHost(conf) === desiredHost) {
  print('already_primary ' + desiredHost);
  quit(0);
}

try {
  rs.initiate(desiredConfig(1));
  print('initialized ' + desiredHost);
} catch (e) {
  print('initiate: ' + e.message);
  const nextVersion = ((conf && conf.version) || 1) + 1;
  try {
    rs.reconfig(desiredConfig(nextVersion), { force: true });
    print('reconfigured ' + desiredHost + ' version=' + nextVersion);
  } catch (reconfigErr) {
    print('reconfig: ' + reconfigErr.message);
    quit(1);
  }
}
