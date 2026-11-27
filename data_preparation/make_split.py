"""
Create data/nested_folds.csv: the outer folds for repeated nested cross-validation.
One row per patient; columns outer_r0, outer_r1, outer_r2 = the outer fold (0-4) of that patient
in each repeat. No fixed test set: in every repeat each patient is in the test part exactly once.

Run once after prepare_failure_data.py (again only if the cohort changes).
Every model (XGBoost, ExpertRuleFit, baselines) reads this file, so all are evaluated on the same folds.
"""
from pathlib import Path

import pandas as pd
from sklearn.model_selection import StratifiedKFold

DATA = Path(__file__).resolve().parents[1] / "data"   # repo/data, wherever you run the script from
SEED, N_FOLDS, N_REPEATS = 42, 5, 3

df = pd.read_parquet(DATA / "failure_features.parquet")[["person_id", "failure"]]
df = df.sort_values("person_id").reset_index(drop=True)   # fixed order -> reproducible folds

nested = df[["person_id"]].copy()
for r in range(N_REPEATS):
    # different shuffle per repeat; stratified, so every fold has the same failure rate (~12%)
    skf_r = StratifiedKFold(n_splits=N_FOLDS, shuffle=True, random_state=SEED + r)
    nested[f"outer_r{r}"] = -1
    for k, (_, pos) in enumerate(skf_r.split(df, df["failure"])):
        nested.loc[pos, f"outer_r{r}"] = k     # df is sorted with a fresh 0..n-1 index: position = label
nested.to_csv(DATA / "nested_folds.csv", index=False)
print(f"nested_folds.csv: {N_REPEATS} repeats x {N_FOLDS} outer folds over all {len(nested)} patients")
