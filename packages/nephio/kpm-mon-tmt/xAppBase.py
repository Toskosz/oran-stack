import os
import socket
import sys
import time
import json
import math
import numbers
import logging
import threading
import urllib.error
import urllib.request

import ricxappframe
from ricxappframe.rmr import rmr
import ricxappframe.xapp_subscribe as subscribe
import ricxappframe.xapp_rest as ricrest
from ricxappframe.e2ap.asn1 import IndicationMsg
from .e2sm_ccc_module import e2sm_ccc_module
from .e2sm_kpm_module import e2sm_types, e2sm_kpm_module
from .e2sm_rc_module import e2sm_rc_module


KPM_METRIC_UNITS = {
    "DRB.PacketSuccessRateUlgNBUu": "-",
    "DRB.UEThpUl": "kbps",
}


class SubscriptionWrapper(object):
    def __init__(self):
        super(SubscriptionWrapper, self).__init__()
        self.e2sm_type = e2sm_types.E2SM_UNKNOWN
        self.subscription_id = None
        self.e2_event_instance_id = None  # Subscription ID used in RIC indication msgs
        self.callback_func = None

class xAppBase(object):
    def __init__(self, config=None, http_server_port=8090, rmr_port=4560, rmr_flags=0x00):
        super(xAppBase, self).__init__()
        # Default Config — Kubernetes-friendly defaults; overridable via env.
        # The submgr binary in i-release has two HTTP servers: port 8080
        # serves /ric/v1/health/alive only; port 8088 serves the actual
        # /ric/v1/subscriptions REST API. The Service is headless
        # (clusterIP=None) so DNS resolves to the pod IP and we connect
        # directly to the right port.
        # xAPP_IP must be reachable by submgr/rtmgr by name; rtmgr only knows
        # the FQDN that appmgr stored at register time, so a pod IP would
        # cause RTMGR route create to fail with HTTP 400. The chart injects
        # XAPP_IP=service-ricxapp-<release>-rmr.ricxapp; fallback to pod IP
        # only for local/dev runs.
        self.xAPP_IP = os.environ.get(
            "XAPP_IP",
            socket.gethostbyname(socket.gethostname()),
        )
        self.MY_HTTP_SERVER_ADDRESS = "0.0.0.0"     # bind to all interfaces
        self.MY_HTTP_SERVER_PORT = http_server_port # web server listen port
        self.MY_RMR_PORT = rmr_port
        self.ADVERTISED_HTTP_PORT = int(os.environ.get(
            "XAPP_ADVERTISED_HTTP_PORT",
            self.MY_HTTP_SERVER_PORT,
        ))
        self.ADVERTISED_RMR_PORT = int(os.environ.get(
            "XAPP_ADVERTISED_RMR_PORT",
            self.MY_RMR_PORT,
        ))
        self.SUB_MGR_URI = os.environ.get(
            "SUB_MGR_URI",
            "http://service-ricplt-submgr-http.ricplt:8088/ric/v1",
        )
        self.APP_MGR_REGISTER_URI = os.environ.get(
            "APP_MGR_REGISTER_URI",
            "http://service-ricplt-appmgr-http.ricplt:8080/ric/v1/register",
        )
        self.XAPP_NAME = os.environ.get("XAPP_NAME")
        self.XAPP_NAMESPACE = os.environ.get("XAPP_NAMESPACE", "ricxapp")
        self.LOG_EVERY = max(1, int(os.environ.get("XAPP_LOG_EVERY", "30")))
        self.xapp_thread = None

        if config is not None:
            # TODO: read config
            pass

        self.e2sm_ccc = e2sm_ccc_module(self)
        self.e2sm_kpm = e2sm_kpm_module(self)
        self.e2sm_rc = e2sm_rc_module(self)
        # dict to store active subscriptions
        self.my_subscriptions = {}
        self._subscription_lock = threading.Lock()
        self._pending_event_instance_ids = {}
        self._unexpected_subscription_ids = set()
        self._metrics_lock = threading.Lock()
        self._rmr_indications_total = 0
        self._kpm_indications_total = 0
        self._rmr_receive_errors_total = 0
        self._kpm_measurements = {}

        # helper variables
        self.running = False

        # Initialize RMR client.  RMR_FLAGS is useful for receive-only xApps
        # deployed outside the RIC cluster: setting it to RMRFL_NOTHREAD (1)
        # disables the route-table collector while keeping the RMR listener.
        # The KPM subscription itself is sent to SubMgr over REST.
        rmr_flags = int(os.environ.get("RMR_FLAGS", str(rmr_flags)), 0)
        initbind = str(self.MY_RMR_PORT).encode('utf-8')
        self.rmr_client = rmr.rmr_init(initbind, rmr.RMR_MAX_RCV_BYTES, rmr_flags)
        while rmr.rmr_ready(self.rmr_client) == 0:
            time.sleep(1)

        rmr.rmr_set_stimeout(self.rmr_client, 1)
        self.rmr_sbuf = None
        time.sleep(0.1)

        # Initialize Subscriber to talk to Subscription Manager over REST API
        self.subscriber = subscribe.NewSubscriber(self.SUB_MGR_URI)

        # Initialize subEndPoint with my IP and ports
        self.subEndPoint = self.subscriber.SubscriptionParamsClientEndpoint(
            self.xAPP_IP,
            self.ADVERTISED_HTTP_PORT,
            self.ADVERTISED_RMR_PORT,
        )

        # Create a HTTP server and set the URI handler callbacks
        self.httpServer = ricrest.ThreadedHTTPServer(self.MY_HTTP_SERVER_ADDRESS, self.MY_HTTP_SERVER_PORT)
        if self.subscriber.ResponseHandler(self._subscription_response_callback, self.httpServer) is not True:
            print("Error when trying to set the subscription reponse callback")
        self.httpServer.handler.add_handler(
            self.httpServer.handler,
            "GET",
            "metrics",
            "/metrics",
            self._metrics_handler,
        )
        self.httpServer.start()

        # Register with appmgr so rtmgr learns this xApp's canonical
        # endpoint. Without this, submgr's "POST /handles/xapp-subscription-handle"
        # to rtmgr returns 400 BadRequest and the SubscriptionRequest is
        # never propagated to the gNB.
        self._register_with_appmgr()

    def _register_with_appmgr(self):
        if not self.XAPP_NAME:
            print("xAppBase: XAPP_NAME not set, skipping appmgr register")
            return
        ns = self.XAPP_NAMESPACE
        rmr_endpoint = os.environ.get(
            "XAPP_RMR_ENDPOINT",
            "service-{ns}-{name}-rmr.{ns}:{port}".format(
                ns=ns, name=self.XAPP_NAME, port=self.MY_RMR_PORT,
            ),
        )
        http_endpoint = os.environ.get(
            "XAPP_HTTP_ENDPOINT",
            "service-{ns}-{name}-http.{ns}:{port}".format(
                ns=ns, name=self.XAPP_NAME, port=self.MY_HTTP_SERVER_PORT,
            ),
        )
        payload = {
            "appName": self.XAPP_NAME,
            "appVersion": "0.1.0",
            "configPath": "",
            "appInstanceName": self.XAPP_NAME,
            "httpEndpoint": http_endpoint,
            "rmrEndpoint": rmr_endpoint,
            # AppMgr uses this embedded descriptor to populate the xApp's
            # txMessages/rxMessages inventory.  RTMgr 0.9.7 only includes
            # subscription routes in a full route-table refresh when at
            # least one of those lists is non-empty.  Omitting it makes the
            # initial partial 12050 route work briefly, then disappear on the
            # next full `newrt` update.
            "config": json.dumps({
                "rmr": {
                    "txMessages": ["RIC_SUB_REQ", "RIC_SUB_DEL_REQ"],
                    "rxMessages": [
                        "RIC_SUB_RESP",
                        "RIC_SUB_FAILURE",
                        "RIC_SUB_DEL_RESP",
                        "RIC_INDICATION",
                    ],
                    "policies": [],
                }
            }),
        }
        req = urllib.request.Request(
            self.APP_MGR_REGISTER_URI,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                print("xAppBase: appmgr register {} -> HTTP {}".format(self.XAPP_NAME, resp.status))
        except urllib.error.HTTPError as e:
            # already registered → 400/409 are expected on restart
            print("xAppBase: appmgr register {} -> HTTP {} ({})".format(self.XAPP_NAME, e.code, e.reason))
        except Exception as e:
            print("xAppBase: appmgr register {} failed: {}".format(self.XAPP_NAME, e))
        # rtmgr polls appmgr ~every 10s; wait so the route exists before
        # the xApp issues its first SubscriptionRequest.
        time.sleep(12)

    @classmethod
    def start_function(cls, fun):
        def wrapper(self, *args, **kwargs):
            self.running = True
            self.xapp_thread = threading.Thread(target=fun, args=(self, *args), kwargs=kwargs)
            self.xapp_thread.start()
            self._run()
        return wrapper

    def _create_http_response(self,status=200, response="OK"):
        return {'response': response, 'status': status, 'payload': None, 'ctype': 'application/json', 'attachment': None, 'mode': 'plain'}

    @staticmethod
    def _prometheus_label(value):
        """Escape a value for the Prometheus text exposition format."""
        return str(value).replace('\\', '\\\\').replace('\n', '\\n').replace('"', '\\"')

    @staticmethod
    def _latest_numeric(values):
        """Return the newest finite numeric value from a decoded KPM record."""
        if not isinstance(values, (list, tuple)):
            values = [values]
        for value in reversed(values):
            if isinstance(value, numbers.Real) and not isinstance(value, bool):
                value = float(value)
                if math.isfinite(value):
                    return value
        return None

    def _record_kpm_measurements(self, e2_agent_id, indication_msg):
        """Store the latest decoded KPM values for Prometheus scraping."""
        meas_data = self.e2sm_kpm.extract_meas_data(indication_msg)
        samples = []

        for metric_name, values in meas_data.get("measData", {}).items():
            value = self._latest_numeric(values)
            if value is not None:
                samples.append((str(metric_name), "node", "", value))

        for ue_id, ue_meas_data in meas_data.get("ueMeasData", {}).items():
            for metric_name, values in ue_meas_data.get("measData", {}).items():
                value = self._latest_numeric(values)
                if value is not None:
                    samples.append((str(metric_name), "ue", str(ue_id), value))

        observed_at = time.time()
        with self._metrics_lock:
            for metric_name, scope, ue_id, value in samples:
                key = (metric_name, str(e2_agent_id), scope, ue_id)
                previous = self._kpm_measurements.get(key, {})
                self._kpm_measurements[key] = {
                    "value": value,
                    "observed_at": observed_at,
                    "updates": previous.get("updates", 0) + 1,
                }

    def _metrics_handler(self, name, path, data, ctype):
        """Expose the minimum delivery/decoding signals in Prometheus format."""
        with self._metrics_lock:
            rmr_total = self._rmr_indications_total
            kpm_total = self._kpm_indications_total
            rmr_receive_errors_total = self._rmr_receive_errors_total
            kpm_measurements = list(self._kpm_measurements.items())
        with self._subscription_lock:
            active_subscriptions = len({
                id(subscription) for subscription in self.my_subscriptions.values()
            })

        response = self._create_http_response()
        response['ctype'] = 'text/plain; version=0.0.4; charset=utf-8'
        payload = (
            '# HELP oran_xapp_rmr_indications_total RIC indication envelopes received over RMR.\n'
            '# TYPE oran_xapp_rmr_indications_total counter\n'
            'oran_xapp_rmr_indications_total {}\n'
            '# HELP oran_xapp_kpm_indications_total KPM indications decoded and dispatched.\n'
            '# TYPE oran_xapp_kpm_indications_total counter\n'
            'oran_xapp_kpm_indications_total {}\n'
            '# HELP oran_xapp_active_subscriptions Active xApp subscription callbacks.\n'
            '# TYPE oran_xapp_active_subscriptions gauge\n'
            'oran_xapp_active_subscriptions {}\n'
            '# HELP oran_xapp_rmr_receive_errors_total Errors raised by the RMR receive loop.\n'
            '# TYPE oran_xapp_rmr_receive_errors_total counter\n'
            'oran_xapp_rmr_receive_errors_total {}\n'
        ).format(
            rmr_total,
            kpm_total,
            active_subscriptions,
            rmr_receive_errors_total,
        )
        payload += (
            '# HELP oran_xapp_kpm_measurement Latest numeric value decoded from an E2SM-KPM indication.\n'
            '# TYPE oran_xapp_kpm_measurement gauge\n'
            '# HELP oran_xapp_kpm_measurement_timestamp_seconds Unix time when the KPM value was received.\n'
            '# TYPE oran_xapp_kpm_measurement_timestamp_seconds gauge\n'
            '# HELP oran_xapp_kpm_measurement_updates_total Number of decoded updates for a KPM series.\n'
            '# TYPE oran_xapp_kpm_measurement_updates_total counter\n'
            '# HELP oran_kpm_drb_packet_success_rate_ul Latest DRB.PacketSuccessRateUlgNBUu value reported by the RAN.\n'
            '# TYPE oran_kpm_drb_packet_success_rate_ul gauge\n'
        )
        for key, sample in sorted(kpm_measurements):
            metric_name, e2_node, scope, ue_id = key
            unit = KPM_METRIC_UNITS.get(metric_name, "unknown")
            labels = (
                'metric="{}",unit="{}",e2_node="{}",scope="{}",ue_id="{}"'
            ).format(*[
                self._prometheus_label(value)
                for value in (metric_name, unit, e2_node, scope, ue_id)
            ])
            series_labels = 'e2_node="{}",scope="{}",ue_id="{}"'.format(*[
                self._prometheus_label(value)
                for value in (e2_node, scope, ue_id)
            ])
            payload += 'oran_xapp_kpm_measurement{{{}}} {:.12g}\n'.format(
                labels, sample["value"]
            )
            payload += 'oran_xapp_kpm_measurement_timestamp_seconds{{{}}} {:.6f}\n'.format(
                labels, sample["observed_at"]
            )
            payload += 'oran_xapp_kpm_measurement_updates_total{{{}}} {}\n'.format(
                labels, sample["updates"]
            )
            if metric_name == "DRB.PacketSuccessRateUlgNBUu":
                payload += 'oran_kpm_drb_packet_success_rate_ul{{{}}} {:.12g}\n'.format(
                    series_labels, sample["value"]
                )
        response['payload'] = payload
        return response

    def _subscription_response_callback(self, name, path, data, ctype):
        data = json.loads(data)
        SubscriptionId = data['SubscriptionId']
        E2EventInstanceId = self._normalize_subscription_id(
            data['SubscriptionInstances'][0]["E2EventInstanceId"]
        )  # subscription ID used in RIC indication
        print("Received Subscription ID to E2EventInstanceId mapping: {} -> {}".format(SubscriptionId, E2EventInstanceId))
        with self._subscription_lock:
            if SubscriptionId in self.my_subscriptions:
                self.my_subscriptions[SubscriptionId].e2_event_instance_id = E2EventInstanceId
                # update the key, as it is more convenient to use E2EventInstanceId that is used in RIC indication msgs
                self.my_subscriptions[E2EventInstanceId] = self.my_subscriptions.pop(SubscriptionId)
            else:
                # SubMgr can POST this callback before Subscribe() returns and
                # the REST subscription ID has been stored.
                self._pending_event_instance_ids[SubscriptionId] = E2EventInstanceId

        response = self._create_http_response()
        response['payload'] = ("{}")
        return response

    @staticmethod
    def _normalize_subscription_id(subscription_id):
        """Use one key type for IDs received from REST JSON and RMR."""
        try:
            return int(subscription_id)
        except (TypeError, ValueError):
            return subscription_id

    def subscribe(self, e2_node_id, ran_function_id, event_trigger_def, action_def, indication_callback, e2sm_type=e2sm_types.E2SM_UNKNOWN):
        action_id = 1 # Now only 1 action in a Subscription Request
        # Need to transform byte data for the REST request
        action_def = [action_def[i] for i in range (0, len(action_def))]
        actionDefinitionList = self.subscriber.ActionToBeSetup(action_id, "report", action_def)

        # Need to transform byte data for the REST request
        event_trigger_def = [event_trigger_def[i] for i in range (0, len(event_trigger_def))]

        xapp_event_instance_id = 1234 # TODO: what is this?
        subsDetail = self.subscriber.SubscriptionDetail(xapp_event_instance_id, event_trigger_def, [actionDefinitionList])

        # Create and send RIC Subscription Request
        subReq = self.subscriber.SubscriptionParams(None, self.subEndPoint, e2_node_id, ran_function_id, None, [subsDetail])
        data, reason, status  = self.subscriber.Subscribe(subReq)

        # Decode RIC Subscription Response
        subResponse = json.loads(data)
        subscription_id = subResponse['SubscriptionId']
        print("Successfully subscribed with Subscription ID: ", subscription_id)

        subscriptionObj = SubscriptionWrapper()
        subscriptionObj.e2sm_type = e2sm_type
        subscriptionObj.subscription_id = subscription_id
        subscriptionObj.callback_func = indication_callback
        # Store active subscription in the dict
        with self._subscription_lock:
            E2EventInstanceId = self._pending_event_instance_ids.pop(subscription_id, None)
            if E2EventInstanceId is None:
                self.my_subscriptions[subscription_id] = subscriptionObj
            else:
                subscriptionObj.e2_event_instance_id = E2EventInstanceId
                self.my_subscriptions[E2EventInstanceId] = subscriptionObj

    def unsubscribe(self, subscription_id):
        print("Unsubscribe Subscription ID: ", subscription_id)
        data, reason, status  = self.subscriber.UnSubscribe(subscription_id)
        if (status == 204):
            print("Successfully unsubscribed from Subscription ID: ", subscription_id)
        else:
            print("Error during unsubscribing from Subscription ID: ", subscription_id)

    def unsubscribe_all(self):
        for e2_event_instance_id, subscriptionObj in self.my_subscriptions.items():
            self.unsubscribe(subscriptionObj.subscription_id)

    def rmr_send(self, e2_node_id, payload, mtype, retries=1):
        sbuf = rmr.rmr_alloc_msg(self.rmr_client, len(payload), mtype=mtype)
        rmr.set_payload_and_length(payload, sbuf)
        rmr.generate_and_set_transaction_id(sbuf)
        sbuf.contents.state = 0
        sbuf.contents.mtype = mtype
        sbuf.contents.sub_id = -1
        rmr.rmr_set_meid(sbuf, e2_node_id.encode("utf8"))
        #print("Pre send summary: {}".format(rmr.message_summary(sbuf)))
        sbuf = rmr.rmr_send_msg(self.rmr_client, sbuf)

    def _run(self):
        # Request a fresh buffer for each timed receive. With RMR 4.9.4, reusing
        # an old buffer can leave the caller blocked on its condition variable
        # even though the transport thread continues reading indications. A
        # timeout may return NULL; the exception path below handles that case.
        print("xAppBase: RMR receive loop started", flush=True)
        while self.running:
            try:
                sbuf = rmr.rmr_torcv_msg(self.rmr_client, None, 500)
                summary = rmr.message_summary(sbuf)
            except Exception as e:
                # rmr_torcv_msg returns a NULL pointer when its 500 ms receive
                # timeout expires. The Python binding raises on dereference,
                # but this is an idle poll, not an RMR transport failure.
                if str(e) == "NULL pointer access":
                    # Yield the GIL to RMR's transport thread. Without this
                    # short pause, repeated idle polls form a hot loop and
                    # can starve delivery even while E2Term reports successful
                    # sends to this endpoint.
                    time.sleep(0.01)
                    continue
                with self._metrics_lock:
                    self._rmr_receive_errors_total += 1
                    error_count = self._rmr_receive_errors_total
                if error_count <= 3 or error_count % 100 == 0:
                    print(
                        "xAppBase: RMR receive error #{}: {}".format(
                            error_count, e
                        ),
                        flush=True,
                    )
                time.sleep(0.01)
                continue

            if summary[rmr.RMR_MS_MSG_STATE] == 0: # RMR_OK
                # Check if RIC INDICATION message
                if (summary['message type'] == 12050):
                    with self._metrics_lock:
                        self._rmr_indications_total += 1
                        envelope_count = self._rmr_indications_total
                    if envelope_count == 1 or envelope_count % self.LOG_EVERY == 0:
                        print(
                            "xAppBase: received RMR envelope #{} mtype=12050 sub_id={} meid={}".format(
                                envelope_count,
                                summary.get('subscription id'),
                                summary.get('meid'),
                            ),
                            flush=True,
                        )
                    e2_agent_id = str(summary['meid'].decode('utf-8'))
                    data = rmr.get_payload(sbuf)
                    try:
                        E2EventInstanceId = self._normalize_subscription_id(
                            summary['subscription id']
                        )
                        ric_indication = IndicationMsg()
                        ric_indication.decode(data)
                        with self._subscription_lock:
                            subscriptionObj = self.my_subscriptions.get(E2EventInstanceId)
                            # Some E2Term/RMR combinations deliver a usable
                            # indication with sub_id=-1 or a differently typed
                            # ID. A single-subscription xApp can safely dispatch
                            # that message to its only registered callback.
                            if subscriptionObj is None:
                                subscriptions = {
                                    id(value): value
                                    for value in self.my_subscriptions.values()
                                }
                                if len(subscriptions) == 1:
                                    subscriptionObj = next(iter(subscriptions.values()))

                        if subscriptionObj is None:
                            if E2EventInstanceId not in self._unexpected_subscription_ids:
                                self._unexpected_subscription_ids.add(E2EventInstanceId)
                                print(
                                    "Dropping RIC indication for unknown subscription ID: {}; "
                                    "known IDs: {}".format(
                                        E2EventInstanceId,
                                        list(self.my_subscriptions.keys()),
                                    )
                                )
                            rmr.rmr_free_msg(sbuf)
                            continue

                        callback_func =  subscriptionObj.callback_func
                        subscription_id = E2EventInstanceId
                        if callback_func is not None:
                            if (subscriptionObj.e2sm_type == e2sm_types.E2SM_KPM):
                                # if RIC Indication from E2SM_KPM then decode
                                indication_hdr, indication_msg = self.e2sm_kpm.unpack_ric_indication(ric_indication)
                                self._record_kpm_measurements(e2_agent_id, indication_msg)
                                callback_func(e2_agent_id, subscription_id, indication_hdr, indication_msg)
                                with self._metrics_lock:
                                    self._kpm_indications_total += 1
                            else:
                                # in other cases just pass undecoded byte data
                                callback_func(e2_agent_id, subscription_id, ric_indication.indication_header, ric_indication.indication_message)
                    except Exception as e:
                        print("Error during RIC indication decoding: {}".format(e))
                        pass
                if (summary['message type'] == 12041):
                    print("Received RIC_CONTROL_ACK")
                if (summary['message type'] == 12042):
                    print("Received RIC_CONTROL_FAILURE")

            rmr.rmr_free_msg(sbuf)

    def stop(self):
        self.unsubscribe_all()
        self.httpServer.stop()
        if self.rmr_sbuf is not None:
            rmr.rmr_free_msg(self.rmr_sbuf)
            self.rmr_sbuf = None
        rmr.rmr_close(self.rmr_client)
        self.running = False
        if (self.xapp_thread is not None):
            self.xapp_thread.join()
        sys.exit(0)

    def signal_handler(self, sig, frame):
        self.stop()
