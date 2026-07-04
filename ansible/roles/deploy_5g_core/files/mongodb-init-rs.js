// Idempotent replica set initialization for Open5GS lab (single-member rs0).
// Run via deploy_5g_core after MongoDB pod is Ready.

try {
  var status = rs.status();
  if (status.ok === 1) {
    print('already_initialized');
    quit(0);
  }
} catch (e) {
  // Replica set not configured yet.
}

try {
  rs.initiate({
    _id: 'rs0',
    members: [{ _id: 0, host: 'mongodb:27017', priority: 1 }]
  });
  print('initialized');
} catch (e) {
  print('init message: ' + e.message);
}
