#!/usr/bin/env python3
import argparse
import signal
from lib.xAppBase import xAppBase

metric_to_unit = {
    "RSRP": "dBm",
    "RSRQ": "dB",
    "CQI": "-",
    #"5QI1QoSflow.Rel.AbnormCallDuration": "-",
    #"5QI1QoSflow.Rel.Average.AbnormCallDuration": "ms",
    #"5QI1QoSflow.Rel.Average.NormCallDuration": "ms",
    #"5QI1QoSflow.Rel.NormCallDuration": "-",
    #"CARR.AverageLayersDl": "-",
    #"CARR.AverageLayersUl": "-",
    #"CARR.MUPDSCHMCSDist": "-",
    #"CARR.MUPDSCHRB": "-",
    #"CARR.MUPUSCHMCSDist": "-",
    #"CARR.MUPUSCHRB": "-",
    #"CARR.MaxTxPwr": "dBm",
    #"CARR.NRCellDU": "dBm",
    #"CARR.PDSCHMCSDist": "-",
    #"CARR.PUSCHMCSDist": "-",
    #"CARR.WBCQIDist": "-",
    #"DRB.AirIfDelayDist": "-",
    #"DRB.AirIfDelayDl": "ms",
    "DRB.AirIfDelayUl": "ms",
    #"DRB.DelayDlNgranUeDist": "-",
    #"DRB.DelayUlNgranUeDist": "-",
    #"DRB.DelayUlNgranUeIncD1Dist": "-",
    #"DRB.EstabAtt": "-",
    #"DRB.EstabAttDC": "-",
    #"DRB.EstabSucc": "-",
    #"DRB.EstabSuccDC": "-",
    #"DRB.F1UpacketLossRateDl": "-",
    #"DRB.F1UpacketLossRateUl": "-",
    #"DRB.F1uPdcpSduVolumeDL": "kbit",
    #"DRB.F1uPdcpSduVolumeUL": "kbit",
    #"DRB.GTPUPathFailure": "-",
    #"DRB.GtpF1DelayDlDist": "-",
    #"DRB.InitialEstabAtt": "-",
    #"DRB.InitialEstabSucc": "-",
    #"DRB.MaxActiveUeDl": "-",
    #"DRB.MaxActiveUeUl": "-",
    #"DRB.MaxEstabSucc": "-",
    #"DRB.MeanActiveUeDl": "-",
    #"DRB.MeanActiveUeUl": "-",
    #"DRB.MeanEstabSucc": "-",
    #"DRB.PDCP.UEThpDl": "kbps",
    #"DRB.PacketLossRateULDist": "-",
    #"DRB.PacketLossRateUl": "-",
    #"DRB.PacketLossRateUu": "-",
    #"DRB.PacketSuccessRateUlgNBUu": "-",#
    #"DRB.PdcpF1DelayDl": "0.1ms",
    #"DRB.PdcpPacketDropRateDl": "-",
    #"DRB.PdcpReordDelayUl": "ms",
    #"DRB.PdcpSduDelayDl": "0.1ms",
    #"DRB.PdcpSduDelayDlDist": "-",
    #"DRB.PdcpSduVolumeDL": "kbit",
    #"DRB.PdcpSduVolumeUL": "kbit",
    #"DRB.PdcpSduVolumeX2DL": "kbit",
    #"DRB.PdcpSduVolumeX2UL": "kbit",
    #"DRB.PdcpSduVolumeXnDL": "kbit",
    #"DRB.PdcpSduVolumeXnUL": "kbit",
    #"DRB.PerDataVolumeDLDist": "-",
    #"DRB.PerDataVolumeULDist": "-",
    #"DRB.RelActNbr": "-",
    #"DRB.ResumeAtt": "-",
    #"DRB.ResumeSucc": "-",
    "DRB.RlcDelayUl": "ms",
    #"DRB.RlcPacketDropRateDLDist": "-",
    "DRB.RlcPacketDropRateDl": "-",#
    "DRB.RlcSduDelayDl": "0.1ms",#
    #"DRB.RlcSduDelayDlDist": "-",
    #"DRB.RlcSduLatencyDl": "0.1ms",
    #"DRB.RlcSduLatencyDlDist": "-",
    #"DRB.RlcSduTransmittedVolumeDL": "kbit",
    "DRB.RlcSduTransmittedVolumeDL": "kbit",#
    #"DRB.RlcSduTransmittedVolumeUL": "kbit",
    "DRB.RlcSduTransmittedVolumeUL": "kbit",#
    #"DRB.SessionTime": "ms",
    "DRB.UEThpDl": "kbps",#
    #"DRB.UEThpDlDist": "-",
    "DRB.UEThpUl": "kbps",#
    #"DRB.UEThpUlDist": "-",
    #"DRB.UEUnresVolDl": "%",
    #"DRB.UEUnresVolUl": "%",
    #"DRB.X2uPdcpSduVolumeDl": "kbit",
    #"DRB.X2uPdcpSduVolumeUl": "kbit",
    #"DRB.XnuPdcpSduVolumeDl": "kbit",
    #"DRB.XnuPdcpSduVolumeUl": "kbit",
    #"GTP.DelayDlPsaUpfNgranDist": "-",
    #"GTP.DelayDlPsaUpfNgranMean": "us",
    #"GTP.InDataPktPacketLossN3gNB": "-",
    #"HO.InterSys.PingPong": "-",
    #"HO.InterSys.TooEarly": "-",
    #"HO.InterSys.TooLate": "-",
    #"HO.InterSys.Unnecessary": "-",
    #"HO.InterSys.bPingPong.NCI": "-",
    #"HO.InterSys.bTooLate.ECGI": "-",
    #"HO.InterSys.bUnnecessary.ECGI": "-",
    #"HO.IntraSys.ToWrongCell": "-",
    #"HO.IntraSys.TooEarly": "-",
    #"HO.IntraSys.TooLate": "-",
    #"HO.IntraSys.bToWrongCell.NCI": "-",
    #"HO.IntraSys.bTooEarly.NCI": "-",
    #"HO.IntraSys.bTooLate.NCI": "-",
    #"L1M.ATADist": "-",
    #"L1M.DL-SS-RSRP": "-",
    #"L1M.DL-SS-SINR": "-",
    #"L1M.PHR1": "-",
    #"L1M.RSRPEutraNbr": "-",
    #"L1M.SS-RSRP": "-",
    #"L1M.SS-RSRPNrNbr": "-",
    #"L1M.SSBBeamRelatedUeNbr": "-",
    #"L1M.UL-SRS-RSRP": "W",
    #"MIMOLayersDLy": "m",
    #"MIMOLayersULy": "m",
    #"MM.ChoExeInterReq.TimeMax": "ms",
    #"MM.ChoExeInterReq.TimeMean": "ms",
    #"MM.ChoExeInterSucc": "-",
    #"MM.ChoExeIntraSucc": "-",
    #"MM.ChoPrepInterFail": "-",
    #"MM.ChoPrepInterFailUes": "-",
    #"MM.ChoPrepInterReq": "-",
    #"MM.ChoPrepInterReqUes": "-",
    #"MM.ChoPrepInterSucc": "-",
    #"MM.ChoPrepInterSuccUes": "-",
    #"MM.ChoPrepIntraReq": "-",
    #"MM.ChoPrepIntraReqUes": "-",
    #"MM.ChoPrepIntraSucc": "-",
    #"MM.ChoPrepIntraSuccUes": "-",
    #"MM.ChoResAlloInterFail": "-",
    #"MM.ChoResAlloInterReq": "-",
    #"MM.ChoResAlloInterSucc": "-",
    #"MM.ConfigInterReqCho": "-",
    #"MM.ConfigInterReqChoUes": "-",
    #"MM.ConfigIntraReqCho": "-",
    #"MM.ConfigIntraReqChoUes": "-",
    #"MM.DapsHoExeInterFail": "-",
    #"MM.DapsHoExeInterReq": "-",
    #"MM.DapsHoExeInterSucc": "-",
    #"MM.DapsHoExeIntraReq": "-",
    #"MM.DapsHoExeIntraSucc": "-",
    #"MM.DapsHoPrepInterFail": "-",
    #"MM.DapsHoPrepInterReq": "-",
    #"MM.DapsHoPrepInterSucc": "-",
    #"MM.DapsHoPrepIntraReq": "-",
    #"MM.DapsHoPrepIntraSucc": "-",
    #"MM.DapsHoResAlloInterFail": "-",
    #"MM.DapsHoResAlloInterReq": "-",
    #"MM.DapsHoResAlloInterSucc": "-",
    #"MM.Ho5gsToEpsFallbackTimeMean": "ms",
    #"MM.HoExeHo5gsToEpsFallbackTimeMean": "ms",
    #"MM.HoExeInterFail": "-",
    #"MM.HoExeInterFreqReq": "-",
    #"MM.HoExeInterFreqSucc": "-",
    #"MM.HoExeInterReq": "-",
    #"MM.HoExeInterReq.TimeMax": "ms",
    #"MM.HoExeInterReq.TimeMean": "ms",
    #"MM.HoExeInterSSBFail": "-",
    #"MM.HoExeInterSSBSucc": "-",
    #"MM.HoExeInterSucc": "-",
    #"MM.HoExeIntraFreqReq": "-",
    #"MM.HoExeIntraFreqSucc": "-",
    #"MM.HoExeIntraReq": "-",
    #"MM.HoExeIntraSucc": "-",
    #"MM.HoIncEpsTo5gsResAlloFail": "-",
    #"MM.HoIncEpsTo5gsResAlloReq": "-",
    #"MM.HoIncEpsTo5gsResAlloSucc": "-",
    #"MM.HoOut5gsToEpsFallbackPrepFail": "-",
    #"MM.HoOut5gsToEpsFallbackPrepReq": "-",
    #"MM.HoOut5gsToEpsFallbackPrepSucc": "-",
    #"MM.HoOut5gsToEpsPrepFail": "-",
    #"MM.HoOut5gsToEpsPrepReq": "-",
    #"MM.HoOut5gsToEpsPrepSucc": "-",
    #"MM.HoOutExe5gsToEpsFail": "-",
    #"MM.HoOutExe5gsToEpsFallbackFail": "-",
    #"MM.HoOutExe5gsToEpsFallbackSucc": "-",
    #"MM.HoOutExe5gsToEpsReq": "-",
    #"MM.HoOutExe5gsToEpsSucc": "-",
    #"MM.HoPrepInterFail": "-",
    #"MM.HoPrepInterReq": "-",
    #"MM.HoPrepInterSucc": "-",
    #"MM.HoPrepIntraReq": "-",
    #"MM.HoPrepIntraSucc": "-",
    #"MM.HoResAlloInterFail": "-",
    #"MM.HoResAlloInterReq": "-",
    #"MM.HoResAlloInterSucc": "-",
    #"MM.Redirection.5gsToEpsFallback": "-",
    #"MR.IntrCellSuccSSBSwitch": "-",
    #"MR.IntraCellSSBSwitchReq": "-",
    #"MR.NRScSRSRSRP": "-",
    #"MR.NRScSSRSRQ": "-",
    #"MR.NRScSSSINR": "-",
    #"MR.SS-RSRQ": "-",
    #"MR.SS-RSRQPerSSB": "-",
    #"MR.SS-SINR": "-",
    #"MR.SS-SINRPerSSB": "-",
    #"MeanTime5QI1Flow.RelDoubleNG": "ms",
    #"PAG.DiscardedNbr": "-",
    #"PAG.DiscardedNbrCnInitiated": "-",
    #"PAG.DiscardedNbrRanInitiated": "-",
    #"PAG.ReceivedNbr": "-",
    #"PAG.ReceivedNbrCnInitiated": "-",
    #"PAG.ReceivedNbrRanIntiated": "-",
    #"PDSCHPRBsLayer": "-",
    #"PEE.AvgPower": "W",
    #"PEE.AvgTemperature": "C",
    #"PEE.Current": "A",
    #"PEE.Energy": "kWh",
    #"PEE.Humidity": "%",
    #"PEE.MaxPower": "W",
    #"PEE.MaxTemperature": "C",
    #"PEE.MinPower": "W",
    #"PEE.MinTemperature": "C",
    #"PEE.Voltage": "V",
    #"PUSCHPRBsLayer": "-",
    #"QF.EstabAttNbr": "-",
    #"QF.EstabFailNbr": "-",
    #"QF.EstabSuccNbr": "-",
    #"QF.InitialEstabAttNbr": "-",
    #"QF.InitialEstabFailNbr": "-",
    #"QF.InitialEstabSuccNbr": "-",
    #"QF.ModNbrAtt": "-",
    #"QF.ModNbrFail": "-",
    #"QF.ModNbrSucc": "-",
    #"QF.RelActNbr": "-",
    #"QF.ReleaseAttNbr": "-",
    #"QF.SessionTimeQoS": "ms",
    #"QF.SessionTimeUE": "ms",
    #"QosFlow.PdcpPduVolumeDL": "kbit",
    #"QosFlow.PdcpPduVolumeUL": "kbit",
    #"QosFlow.PdcpSduVolumeDl": "kbit",
    #"QosFlow.PdcpSduVolumeUl": "kbit",
    #"RACH.AccessDelayDist": "-",
    #"RACH.PreambleA": "-",
    #"RACH.PreambleACell": "-",
    #"RACH.PreambleB": "-",
    #"RACH.PreambleBCell": "-",
    #"RACH.PreambleDed": "-",
    "RACH.PreambleDedCell": "-",
    #"RACH.PreambleDist": "-",
    #"RRC.ConnEstabAtt": "-",
    #"RRC.ConnEstabFailCause": "-",
    #"RRC.ConnEstabSucc": "-",
    #"RRC.ConnMax": "%",
    #"RRC.ConnMean": "-",
    #"RRC.InactiveConnMax": "-",
    #"RRC.InactiveConnMean": "-",
    #"RRC.ReEstabAtt": "-",
    #"RRC.ReEstabFallbackToSetupAtt": "-",
    #"RRC.ReEstabSuccWithUeContext": "-",
    #"RRC.ReEstabSuccWithoutUeContext": "-",
    #"RRC.ResumeAtt": "-",
    #"RRC.ResumeFallbackToSetupAtt": "-",
    #"RRC.ResumeFollowedbyNetworkRelease": "-",
    #"RRC.ResumeFollowedbySuspension": "-",
    #"RRC.ResumeSucc": "-",
    #"RRC.ResumeSuccByFallback": "-",
    #"RRU.MaxLayerDlMimo": "-",
    #"RRU.MaxLayerUlMimo": "-",
    #"RRU.MaxPrbUsedDl": "-",
    #"RRU.MaxPrbUsedUl": "-",
    "RRU.PrbAvailDl": "-",#
    "RRU.PrbAvailUl": "-",#
    "RRU.PrbTotDl": "%",#
    #"RRU.PrbTotDlDist": "%",
    #"RRU.PrbTotDlMimo": "%",
    #"RRU.PrbTotSdmDl": "%",
    #"RRU.PrbTotSdmUl": "%",
    "RRU.PrbTotUl": "%",#
    #"RRU.PrbTotUlDist": "%",
    #"RRU.PrbTotUlMimo": "%",
    "RRU.PrbUsedDl": "-",
    "RRU.PrbUsedUl": "-",
    #"SM.MaxPDUSessionSetupReq": "-",
    #"SM.MeanPDUSessionSetupReq": "-",
    #"SM.PDUSessionSetupFail": "-",
    #"SM.PDUSessionSetupReq": "-",
    #"SM.PDUSessionSetupSucc": "-",
    #"TB.ErrNbrUlInitial": "-",
    #"TB.ErrTotNbrDl": "-",
    #"TB.ErrTotNbrUl": "-",
    #"TB.IntialErrNbrDl": "-",
    #"TB.ResidualErrNbrDl": "-",
    #"TB.ResidualErrNbrUl": "-",
    #"TB.TotNbrDl": "-",
    #"TB.TotNbrDlInitial": "-",
    #"TB.TotNbrUl": "-",
    #"TB.TotNbrUlInit": "-",
    #"UECNTX.ConnEstabAtt": "-",
    #"UECNTX.ConnEstabSucc": "-",
    #"UECNTX.RelCmd": "-",
    #"UECNTX.RelReq": "-",
    #"VR.VCpuUsageMean": "%",
    #"VR.VDiskUsageMean": "%",
    #"VR.VMemoryUsageMean": "%",
}


class MyXapp(xAppBase):
    def __init__(self, http_server_port, rmr_port):
        super(MyXapp, self).__init__('', http_server_port, rmr_port)
        self.ue_dl_tx_data = {}
        self.min_prb_ratio = 1
        self.max_prb_ratio1 = 10
        self.max_prb_ratio2 = 100
        self.cur_ue_max_prb_ratio = {}
        self.dl_tx_data_threshold_mb = 20

    def my_subscription_callback(self, e2_agent_id, subscription_id, indication_hdr, indication_msg, kpm_report_style, ue_id):
        indication_hdr = self.e2sm_kpm.extract_hdr_info(indication_hdr)
        meas_data = self.e2sm_kpm.extract_meas_data(indication_msg)
        print("Data Monitoring:")
        print("  E2SM_KPM RIC Indication Content:")
        print("  -ColletStartTime: ", indication_hdr['colletStartTime'])
        print("  -Measurements Data:")
        print("  --UE_id: {}".format(ue_id))
        granulPeriod = meas_data.get("granulPeriod", None)
        if granulPeriod is not None:
            print("  ---granulPeriod: {}".format(granulPeriod))
        for (metric_name, values) in meas_data["measData"].items():
            print("  ---Metric: {}, Value: {:.1f} [{}]".format(metric_name, sum(values), metric_to_unit[metric_name]))
        print("------------------------------------------------------------------")
        print("")

    # Mark the function as xApp start function using xAppBase.start_function decorator.
    # It is required to start the internal msg receive loop.
    @xAppBase.start_function
    def start(self, e2_node_id, kpm_report_style, ue_ids, metric_names):
        report_period = 1000
        granul_period = 1000
        subscription_callback = lambda agent, sub, hdr, msg: self.my_subscription_callback(agent, sub, hdr, msg,
                                                                                           kpm_report_style, ue_ids[
                                                                                               0])  # Dummy condition that is always satisfied
        matchingUeConds = [{'testCondInfo': {'testType': ('ul-rSRP', 'true'), 'testExpr': 'lessthan',
                                             'testValue': ('valueInt', 1000)}}]

        print("Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, metrics: {}".format(e2_node_id,
                                                                                                      kpm_report_style,
                                                                                                      metric_names))
        self.e2sm_kpm.subscribe_report_service_style_1(e2_node_id, report_period, metric_names, granul_period,
                                                       subscription_callback)
if __name__ == '__main__':

    parser = argparse.ArgumentParser(description='My example xApp')
    parser.add_argument("--http_server_port", type=int, default=8090, help="HTTP server listen port")
    parser.add_argument("--rmr_port", type=int, default=4560, help="RMR port")
    parser.add_argument("--e2_node_id", type=str, default='gnbd_001_001_00019b_0', help="E2 Node ID")
    parser.add_argument("--ran_func_id", type=int, default=2, help="RAN function ID")
    parser.add_argument("--kpm_report_style", type=int, default=1, help="KPM Report Style ID")
    parser.add_argument("--ue_ids", type=str, default='0', help="UE ID")
    parser.add_argument("--metrics", type=str, default=",".join(list(metric_to_unit.keys())),
                        help="Metrics name as comma-separated string")
    args = parser.parse_args()
    e2_node_id = args.e2_node_id  # TODO: get available E2 nodes from SubMgr, now the id has to be given.
    ran_func_id = args.ran_func_id  # TODO: get available E2 nodes from SubMgr, now the id has to be given.
    ue_ids = list(map(int, args.ue_ids.split(",")))  # Note: the UE id has to exist at E2 node!
    kpm_report_style = args.kpm_report_style
    metrics = args.metrics.split(",")  # Create MyXapp.
    myXapp = MyXapp(args.http_server_port, args.rmr_port)
    myXapp.e2sm_kpm.set_ran_func_id(ran_func_id)  # Connect exit signals.
    signal.signal(signal.SIGQUIT, myXapp.signal_handler)
    signal.signal(signal.SIGTERM, myXapp.signal_handler)
    signal.signal(signal.SIGINT, myXapp.signal_handler)  # Start xApp.
    myXapp.start(e2_node_id, kpm_report_style, ue_ids, metrics)
    # Note: xApp will unsubscribe all active subscriptions at exit.
