# Contributor analysis (sensitivity) merge: writes macroScript.txt. Assembled before merge-template.sh by yamls/general.yaml.
result_ext=hlm

write_macro() {
    cat > macroScript.txt <<END
//Generic Needed
DCSVERS	200
DCSMSSG	1  0 // 1st 0 MEANS print-msg is OFF; 2nd 0 MEANS using RELATIVE path
DCSWORK .
DCSCOMPLIANT 1
DCSMECHANICAL 1

//load a model (wtx)
DCSLOAD ${dcs_model_file}

DCSSENS_MERGE ${num_results} ${model_name}.hlm
END
    for f in Results/"${model_name}"_*.hlm; do
        echo "DCS_DATA $(basename "${f}")" >> macroScript.txt
    done
    cat >> macroScript.txt <<END
DCSSENS_LOAD ${model_name}
//Activating DCSREPORT_GEN breaks DCSSENS_SAVE
//DCSREPORT_GEN 1 ./reports
//DCSSENS ${model_name}

//save sens as rss
DCSSENS_SAVE 1 ${model_name}_HLM_RSLT
//save sens as html
DCSSENS_SAVE 2 ${model_name}_HLM_RSLT
//save sens as StatRowCsv
DCSSENS_SAVE 3 ${model_name}_HLM_RSLT

END
}
