"""
Download the failure model tables from BigQuery and build failure_features.parquet.
Essentially it combines the 4 feature tables into one table with 1 row per extubation.
Run once after the SQL scripts 01 (v2), 03 and 06.

Output: failure_features.parquet  (input data for nested_cv_xgb.py and nested_cv_erf.py)
        feature_summary.csv       (use as checks before training, for things like units, and amount of missing values)
"""
from pathlib import Path

import pandas as pd
from google.cloud import bigquery

PROJECT = "project-71f189c0-e73d-403e-989" # Google cloud project ID
OUT = f"{PROJECT}.extubation"     # the dataset in the Big Query cloud

# output folder repo/data (next to data_prep/). __file__ = this script, .resolve() = its full path,
# .parents[1] = two levels up (data_prep/ -> repo root), so it works wherever you run the script from
DATA = Path(__file__).resolve().parents[1] / "data"
DATA.mkdir(exist_ok=True)   # create the folder if it does not exist yet

client = bigquery.Client(project=PROJECT) # creates connection to big query, looks up login credentials, need to log in once beforehand in terminal

def q(table):
    # Select the entire table from bigquery and load it into a pandas dataframe
    return client.query(f"SELECT * FROM `{OUT}.{table}`").to_dataframe()

base = q("failure_feat_base") # one row per extubation: label, ventilation duration, age, sex, suctioning, weight/height/BMI, urine output
num = q("failure_feat_num") # extubation x numeric variable: last, mean_6h, min_24h, max_24h, slope_24h
cat = q("failure_feat_cat") # extubation x catergorical variable: last value of ventilation mode, sputum, cough reflex, secretion amount
extra = q("failure_feat_extra") # one row per extubation: extra features like diagnoses, medication, observations, APACHE, sedation days

# convert long to wide: one column per variable x numerical statistic
stats = ["last_val", "mean_6h", "min_24h", "max_24h", "slope_24h"]
# pivot makes the index (episode = extubation here) each a row, where columns="feature", values=stats makes each feature a column, each with 5 statistics
# thus the result has two levels of column names: first the statistic and then the variable
num_w = num.pivot(index="episode_id", columns="feature", values=stats) #cell becomes NaN if row had no measurement of a variable

#turn the two-level column names into combined readable names for 1 level column and assign them in order as new column names
num_w.columns = [f"{feat}_{stat.replace('_val', '')}" for stat, feat in num_w.columns]

#only 1 value so pivot return one level column names (only the features/variables), then just add suffix to each column
cat_w = cat.pivot(index="episode_id", columns="feature", values="last_val").add_suffix("_last")

#set episode_id as row labels for base and extra (now still row numbers), episode_id already row label of base and cat due to pivot index
# then left join all the columns of the three other tables into base table. left join means keep all rows of base,
# even if not present in another table (those columns then become NaN for that row)
df = base.set_index("episode_id").join(num_w).join(cat_w).join(extra.set_index("episode_id")).reset_index() #turn index into row numbers at the end

# BigQuery NUMERIC columns (e.g. values taken directly from value_as_number, such as the APACHE score or weight)
# arrive as Python Decimal objects, so pandas stores the column as dtype "object" (= treated as text).
# Try to convert every object column to numbers: values that are not a number become NaN (errors="coerce").
# Only if NO value was lost (same number of non-missing values before and after) was the column numeric,
# then replace it by floats. Real text columns (e.g. admitted_from) lose all values, so they stay text.
for c in df.columns:
    if df[c].dtype == object:
        converted = pd.to_numeric(df[c], errors="coerce")
        if converted.notna().sum() == df[c].notna().sum() and df[c].notna().any(): # notna().any(): skip columns that are completely empty
            df[c] = converted.astype(float)

# conver true/false flags to 1.0/0.0. died_without_reintubation skipped because used as flag later (see below)
flag_cols = [c for c in df if str(df[c].dtype) in ("bool", "boolean") and c != "died_without_reintubation"]
df[flag_cols] = df[flag_cols].astype(float)


def col(name):  # a column may be missing if a variable had no data at all, then return all NaN instead of erroring
    return df[name] if name in df else pd.Series(float("nan"), index=df.index)


# derived clinical variables
df["rsbi_mean_6h"] = col("rr_total_mean_6h") / (col("vt_exp_mean_6h") / 1000)  # convert VT mL to L
df["pf_ratio_last"] = col("po2_last") / col("fio2_set_last")   #mmHg

# anion gap (mmol/L): use the measured value if there is one, otherwise compute it from the last
# sodium, chloride and bicarbonate: AG = Na - (Cl + HCO3). fillna only fills the rows where the measured value is missing
df["anion_gap_last"] = col("anion_gap_last").fillna(col("sodium_last") - (col("chloride_last") + col("hco3_last")))
# albumin-corrected anion gap (Figge): AG + 0.25 x (40 - albumin [g/L]).
# low albumin (common in the ICU) lowers the anion gap and can hide an acidosis, this corrects for it
df["anion_gap_corr_last"] = col("anion_gap_last") + 0.25 * (40 - col("albumin_last"))

# GCS eye + motor (verbal is not realiably assessable while intubated)
# sum the two column values per row, only if both present (else NaN), otherwise missing interpreted as 0 which articifially lowers scores
df["gcs_em_last"] = pd.concat([col("gcs_eye_last"), col("gcs_motor_last")], axis=1).sum(axis=1, min_count=2)

# ventilation mode, 95% is "assisted" so convert to a binary flag that indicated whether last ventilation mode is "assisted"
# or some other. Prevents rare ventilation modes from adding noise / prevent overfitting
if "vent_mode_last" in df:
    controlled = ["Controlled ventilation", "SIMV(PC)+PS", "Mandatory minute ventilation"]
    df["vent_controlled_last"] = df["vent_mode_last"].isin(controlled).astype(float) # 0 if assisted, 1 if one of other three
    # isin also returns False for a missing value, which gets converted to 0 = assited falsely, so convert missing values to NaN:
    df.loc[df["vent_mode_last"].isna(), "vent_controlled_last"] = float("nan")
    df = df.drop(columns="vent_mode_last") # drop old column

df["failure"] = df["failure"].astype(int) #convert label to whole number to represent real label

# division by zero (e.g. tidal volume 0 or FiO2 0) gives inf, instead exclude (missing) since not meaningfull signal
num_cols = df.select_dtypes("number").columns # select numeric column
n_inf = int(df[num_cols].isin([float("inf"), float("-inf")]).sum().sum()) #sum all +- inf values (first per numeric column and then over all numeric columns)
df[num_cols] = df[num_cols].replace([float("inf"), float("-inf")], float("nan")) #replace +- inf values with NaN
print(f"replaced {n_inf} infinite values with NaN")

# keep everyone who did not die without reintubation. Might exlcude patients here that died because reintubation failed so badly,
# but also exclude patients that were extubated as comfort care before death for example
df = df[~df["died_without_reintubation"].astype(bool)]
df.to_parquet(DATA / "failure_features.parquet", index=False) # save final table as parquet file

# describe some stats per variables for manual sanity checks
summary = df.describe(percentiles=[.05, .5, .95], include="all").T #transpose so each row is a variable
summary["missing_pct"] = (df.isna().mean() * 100).round(1) #percentage of missing values in each column
summary.to_csv(DATA / "feature_summary.csv")
print(f"{len(df)} extubations, {df.shape[1]} columns, failure rate {df['failure'].mean():.3f}")
