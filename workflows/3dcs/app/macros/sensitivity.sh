# Contributor analysis (sensitivity) worker: writes macroScript.txt. Assembled before worker-template.sh by yamls/general.yaml.
result_ext=hlm

write_macro() {
    cat > macroScript.txt <<END
DCSVERS	200
DCSMSSG	1  0
DCSWORK .
DCSCOMPLIANT 1
DCSMECHANICAL 1
DCS_CFG_MP_PROGRESS_SETTING 1 10

DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_lsqgeomv.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_3devmove.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_AxisTol.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_calcdir.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_CntrPntTl.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_floatMv.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_formTl.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_linfloat.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_loopMv.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_lsqgeomv.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_mtmlib1.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_mtmlib2.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_MultiPtTrans.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_NestMove.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_Polyfloat.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_vblock.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\Extra_Dlls\dcu_xformMv.dll


DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_autobend.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_avgmove.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_cr2cr.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_avgtole.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_cmmdev2.dll
DCSLOADDLL1 C:\Program Files\DCS\3DCS_MC_8_0_0_2\addIns\dcu_stat_row.dll
DCS_DEL_FILE *.hlm

DCSLOAD ${dcs_model_file}

DCS_CFG_SETTING ${dcs_thread} 0

DCSSENS_CONTRIBUTOR ${dcs_concurrency} ${case_index} ${result_name}

END
}
