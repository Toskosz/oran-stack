// MongoDB initialization script for Open5GS WebUI
// Initializes admin user and sample subscriber data
// This script runs automatically when MongoDB starts for the first time

// Use the 'admin' database for user authentication
db = db.getSiblingDB('admin');

// Initialize admin user for WebUI access
try {
    const adminResult = db.administrators.updateOne(
        { username: 'admin' },
        {
            $setOnInsert: {
                username: 'admin',
                // Password: '1423' hashed with bcrypt (pre-computed for testing)
                // In production, use proper password hashing
                password: '$2a$10$9D3nYrAb.tF.lL.hzjvJJOTxMTtDZdv/mUwvN8OJZBJLwYMrKvEOq',
                created_at: new Date(),
                updated_at: new Date()
            }
        },
        { upsert: true }
    );

    if (adminResult.upsertedCount === 1) {
        print('Admin user initialized: admin / 1423');
    } else {
        print('Admin user already exists: admin');
    }
} catch (e) {
    print('Admin user info: ' + e.message);
}

// Switch to the 'open5gs' database for subscriber data
db = db.getSiblingDB('open5gs');

// Initialize sample 5G subscriber
// IMSI: 001010000000001 (MCC: 001, MNC: 01, matching .env PLMN config)
try {
    const sub5gResult = db.subscribers.updateOne(
        { imsi: '001010000000001' },
        {
            $setOnInsert: {
                imsi: '001010000000001',
                msisdn: '+82100000001',
                imeisv: '4819690300000000',
                imei: '481969030000000',
                mdn: '',
                urn: 'urn:3gpp:imsi:001010000000001',
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
                        sd: 1,
                        default: true
                    },
                    {
                        sst: 1,
                        sd: 5,
                        default: false
                    }
                ],
                // Schema version for compatibility
                schema_version: 1,
                created_at: new Date(),
                updated_at: new Date()
            }
        },
        { upsert: true }
    );

    if (sub5gResult.upsertedCount === 1) {
        print('Sample 5G subscriber initialized: IMSI 001010000000001');
    } else {
        print('Sample 5G subscriber already exists: IMSI 001010000000001');
    }
} catch (e) {
    print('Sample subscriber info: ' + e.message);
}

// Initialize 5G subscriber for Slice 2 (SST=1, SD=5)
// IMSI: 001010000000003 (second 5G UE for anomaly detection slice 2)
try {
    const sub5g2Result = db.subscribers.updateOne(
        { imsi: '001010000000003' },
        {
            $setOnInsert: {
                imsi: '001010000000003',
                msisdn: '+82100000003',
                imeisv: '4819690300000002',
                imei: '481969030000002',
                mdn: '',
                urn: 'urn:3gpp:imsi:001010000000003',
                subscriber_status: 0,
                network_access_mode: 0,
                access_restriction_data: 32,
                subscribed_rau_tau_timer: 12,
                pdn: [
                    {
                        apn: 'internet',
                        type: 2,
                        dnn: 'internet',
                        qci: 9,
                        arp: {
                            priority_level: 8,
                            pre_emption_capability: 0,
                            pre_emption_vulnerability: 0
                        },
                        mbr: {
                            downlink: 1024,
                            uplink: 1024
                        },
                        ambr: {
                            downlink: 1024000,
                            uplink: 1024000
                        }
                    }
                ],
                ambr: {
                    downlink: 1024000,
                    uplink: 1024000
                },
                // Slice 2 only: SST=1, SD=5
                slice: [
                    {
                        sst: 1,
                        sd: 5,
                        default: true
                    }
                ],
                schema_version: 1,
                created_at: new Date(),
                updated_at: new Date()
            }
        },
        { upsert: true }
    );

    if (sub5g2Result.upsertedCount === 1) {
        print('Slice-2 5G subscriber initialized: IMSI 001010000000003');
    } else {
        print('Slice-2 5G subscriber already exists: IMSI 001010000000003');
    }
} catch (e) {
    print('Slice-2 subscriber info: ' + e.message);
}

// Auth context for slice-2 5G subscriber
try {
    const auth5g2Result = db.auths.updateOne(
        { imsi: '001010000000003' },
        {
            $setOnInsert: {
                imsi: '001010000000003',
                k: '465B5CE8B199B49FAA5F0A2EE238A6BC',
                opc: 'E8ED289DEBA952E4283B54E88E6183CA',
                amf: 32770,
                sqn: 0,
                ck: null,
                ik: null,
                created_at: new Date(),
                updated_at: new Date()
            }
        },
        { upsert: true }
    );

    if (auth5g2Result.upsertedCount === 1) {
        print('Security context initialized for Slice-2 5G subscriber');
    } else {
        print('Security context already exists for Slice-2 5G subscriber');
    }
} catch (e) {
    print('Slice-2 auth info: ' + e.message);
}

// Initialize sample 4G subscriber
// IMSI: 001010000000002
try {
    const sub4gResult = db.subscribers.updateOne(
        { imsi: '001010000000002' },
        {
            $setOnInsert: {
                imsi: '001010000000002',
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
            }
        },
        { upsert: true }
    );

    if (sub4gResult.upsertedCount === 1) {
        print('Sample 4G subscriber initialized: IMSI 001010000000002');
    } else {
        print('Sample 4G subscriber already exists: IMSI 001010000000002');
    }
} catch (e) {
    print('Sample 4G subscriber info: ' + e.message);
}

// Initialize security context for 5G subscriber
// Keys match the srsUE configuration in srsran/configs/ue.conf
try {
    const auth5gResult = db.auths.updateOne(
        { imsi: '001010000000001' },
        {
            $setOnInsert: {
                imsi: '001010000000001',
                // K (128-bit secret key) - must match ue.conf
                k: '465B5CE8B199B49FAA5F0A2EE238A6BC',
                // OPc (Operator-specific key) - must match ue.conf
                opc: 'E8ED289DEBA952E4283B54E88E6183CA',
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
            }
        },
        { upsert: true }
    );

    if (auth5gResult.upsertedCount === 1) {
        print('Security context initialized for 5G subscriber');
    } else {
        print('Security context already exists for 5G subscriber');
    }
} catch (e) {
    print('Security context info: ' + e.message);
}

// Initialize security context for 4G subscriber
try {
    const auth4gResult = db.auths.updateOne(
        { imsi: '001010000000002' },
        {
            $setOnInsert: {
                imsi: '001010000000002',
                k: '465B5CE8B199B49FAA5F0A2EE238A6BC',
                opc: 'E8ED289DEBA952E4283B54E88E6183CA',
                amf: 32770,
                sqn: 0,
                ck: null,
                ik: null,
                created_at: new Date(),
                updated_at: new Date()
            }
        },
        { upsert: true }
    );

    if (auth4gResult.upsertedCount === 1) {
        print('Security context initialized for 4G subscriber');
    } else {
        print('Security context already exists for 4G subscriber');
    }
} catch (e) {
    print('Security context info: ' + e.message);
}

print('=================================================');
print('MongoDB initialization complete');
print('=================================================');
print('');
print('Sample 5G Subscriber:');
print('  IMSI: 001010000000001');
print('  APN: internet');
print('  K: 465B5CE8B199B49FAA5F0A2EE238A6BC');
print('  OPc: E8ED289DEBA952E4283B54E88E6183CA');
print('');
print('Sample 4G Subscriber:');
print('  IMSI: 001010000000002');
print('  APN: internet');
print('  K: 465B5CE8B199B49FAA5F0A2EE238A6BC');
print('  OPc: E8ED289DEBA952E4283B54E88E6183CA');
print('');
print('WebUI Access:');
print('  URL: http://localhost:9999');
print('  Username: admin');
print('  Password: 1423');
print('');
