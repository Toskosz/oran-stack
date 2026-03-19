// Initialize MongoDB replica set for Open5GS testing
// This script runs automatically when MongoDB starts for the first time

try {
    rs.initiate({
        _id: 'rs0',
        members: [
            {
                _id: 0,
                host: 'mongodb:27017',
                priority: 1
            }
        ]
    });
    print('Replica set initialized successfully');
} catch (e) {
    // Replica set might already be initialized
    print('Replica set initialization message: ' + e.message);
}
