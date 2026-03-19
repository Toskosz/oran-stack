// MongoDB initialization script for Open5GS WebUI
// Initializes admin user and sample subscriber data
// This script runs automatically when MongoDB starts for the first time

// Use the 'admin' database for user authentication
db = db.getSiblingDB('admin');

// Initialize admin user for WebUI access
try {
    db.administrators.insertOne({
        username: 'admin',
        // Password: '1423' hashed with bcrypt (pre-computed for testing)
        // In production, use proper password hashing
        password: '$2a$10$9D3nYrAb.tF.lL.hzjvJJOTxMTtDZdv/mUwvN8OJZBJLwYMrKvEOq',
        created_at: new Date(),
        updated_at: new Date()
    });
    print('Admin user initialized: admin / 1423');
} catch (e) {
    print('Admin user info: ' + e.message);
}

// Switch to the 'open5gs' database for subscriber data
db = db.getSiblingDB('open5gs');

// Initialize sample 5G subscriber
// IMSI: 999700000000001 (MCC: 999, MNC: 70, matching original default PLMN)
try {
    db.subscribers.insertOne({
        imsi: '999700000000001',
        msisdn: '+82100000001',
        imeisv: '4819690300000000',
        imei: '481969030000000',
        mdn: '',
        urn: 'urn:3gpp:imsi:999700000000001',
        // Subscriber status: 0 = ServiceGranted
        subscriber_status: 0,
        // Network access mode: 0 = PacketAndCircuit
        network_access_mode: 0,
        // Access restriction data
        access_restriction_data: 32,
        // Subscribed RAU/TAU timer
        subscribed_rau_tau_timer: 12,
        // PDN (Packet Data Network) configuration
        pdn: [
            {
                apn: 'internet',
                // Type: 2 = IPv4
                type: 2,
                dnn: 'internet',
                // QoS Class Identifier: 9 = best effort
                qci: 9,
                arp: {
                    priority_level: 8,
                    pre_emption_capability: 0,
                    pre_emption_vulnerability: 0
                },
                // Maximum Bit Rate (Mbps)
                mbr: {
                    downlink: 1024,
                    uplink: 1024
                },
                // Aggregate Maximum Bit Rate
                ambr: {
                    downlink: 1024000,
                    uplink: 1024000
                }
            }
        ],
        // Aggregate Maximum Bit Rate
        ambr: {
            downlink: 1024000,
            uplink: 1024000
        },
        // Network Slice Single Assignment (NSSAI)
        slice: [
            {
                sst: 1,
                default: true
            }
        ],
        // Schema version for compatibility
        schema_version: 1,
        created_at: new Date(),
        updated_at: new Date()
    });
    print('Sample 5G subscriber initialized: IMSI 999700000000001');
} catch (e) {
    print('Sample subscriber info: ' + e.message);
}

// Initialize sample 4G subscriber
// IMSI: 999700000000002
try {
    db.subscribers.insertOne({
        imsi: '999700000000002',
        msisdn: '+82100000002',
        imeisv: '4819690300000001',
        imei: '481969030000001',
        pdn: [
            {
                apn: 'internet',
                type: 2,
                qci: 9,
                arp: {
                    priority_level: 8,
                    pre_emption_capability: 0,
                    pre_emption_vulnerability: 0
                },
                mbr: {
                    downlink: 1024,
                    uplink: 1024
                }
            }
        ],
        ambr: {
            downlink: 1024000,
            uplink: 1024000
        },
        subscriber_status: 0,
        network_access_mode: 0,
        access_restriction_data: 32,
        subscribed_rau_tau_timer: 12,
        schema_version: 1,
        created_at: new Date(),
        updated_at: new Date()
    });
    print('Sample 4G subscriber initialized: IMSI 999700000000002');
} catch (e) {
    print('Sample 4G subscriber info: ' + e.message);
}

// Initialize security context for 5G subscriber
// Standard test keys (K, OPc, etc.)
try {
    db.auths.insertOne({
        imsi: '999700000000001',
        // K (128-bit secret key) - test value
        k: '8baf473f2f8fd09487cccbd7097c6862',
        // OPc (Operator-specific key) - test value  
        opc: '8e27b6af0e692e750f32667a3b14605d',
        // AMF (Authentication Management Field) - default 0x8000
        amf: 32770,
        // SQN (Sequence Number)
        sqn: 0,
        // CK (Confidentiality Key) - optional
        ck: null,
        // IK (Integrity Key) - optional
        ik: null,
        created_at: new Date(),
        updated_at: new Date()
    });
    print('Security context initialized for 5G subscriber');
} catch (e) {
    print('Security context info: ' + e.message);
}

// Initialize security context for 4G subscriber
try {
    db.auths.insertOne({
        imsi: '999700000000002',
        k: '8baf473f2f8fd09487cccbd7097c6862',
        opc: '8e27b6af0e692e750f32667a3b14605d',
        amf: 32770,
        sqn: 0,
        ck: null,
        ik: null,
        created_at: new Date(),
        updated_at: new Date()
    });
    print('Security context initialized for 4G subscriber');
} catch (e) {
    print('Security context info: ' + e.message);
}

print('=================================================');
print('MongoDB initialization complete');
print('=================================================');
print('');
print('Sample 5G Subscriber:');
print('  IMSI: 999700000000001');
print('  APN: internet');
print('  K: 8baf473f2f8fd09487cccbd7097c6862');
print('  OPc: 8e27b6af0e692e750f32667a3b14605d');
print('');
print('Sample 4G Subscriber:');
print('  IMSI: 999700000000002');
print('  APN: internet');
print('  K: 8baf473f2f8fd09487cccbd7097c6862');
print('  OPc: 8e27b6af0e692e750f32667a3b14605d');
print('');
print('WebUI Access:');
print('  URL: http://localhost:9999');
print('  Username: admin');
print('  Password: 1423');
print('');
