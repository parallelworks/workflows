# Monte Carlo merge: writes macroScript.txt. Assembled before merge-template.sh by yamls/general.yaml.
result_ext=hst

write_macro() {
    cat > macroScript.txt <<END
//Generic Needed
DCSVERS	200
DCSMSSG	1  0 // 1st 0 MEANS print-msg is OFF; 2nd 0 MEANS using RELATIVE path
DCSWORK .
DCSCOMPLIANT 1
DCSMECHANICAL 1
DCSLOAD_CFG dcs4d.cfg

//load a model (wtx)
DCSLOAD ${dcs_model_file}

//merge results files (in Results folder)
DCSSIMU_MERGE ${num_results} ${model_name}.hst
END
    for f in Results/"${model_name}"_*.hst; do
        echo "DCS_DATA $(basename "${f}")" >> macroScript.txt
    done
    cat >> macroScript.txt <<END
DCSSIMU_LOAD ${model_name}
//Activating DCSREPORT_GEN breaks DCSSENS_SAVE
//DCSREPORT_GEN 1 ./reports

//save simu as rsh
DCSSIMU_SAVE 1 ${model_name}_HST_RSLT
//save simu as rel
DCSSIMU_SAVE 2 ${model_name}_HST_RSLT
//save simu as csv
DCSSIMU_SAVE 3 ${model_name}_HST_RSLT
//save simu as html
DCSSIMU_SAVE 4 ${model_name}_HST_RSLT
//save simu as raw
DCSSIMU_SAVE 7 ${model_name}_HST_RSLT
//save simu as cmmdev
DCSSIMU_SAVE 8 ${model_name}_HST_RSLT
//save simu as hsu
DCSSIMU_SAVE 9 ${model_name}

END
}
