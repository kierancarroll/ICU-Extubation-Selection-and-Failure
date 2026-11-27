"""
Repeated nested cross-validation for the extubation failure model (XGBoost + Optuna).

Outer loop : 3 repeats x 5 folds over ALL patients (nested_folds.csv, from make_split.py)
             -> every patient is predicted 3 times, each time by a model that never saw them
Inner loop : Optuna tuning with 5-fold CV inside the outer training part only
Per outer fold: final model -> predictions + exact TreeSHAP values for the held-out patients

Outputs (folder nested_cv/):
  fold_r{r}_k{k}.parquet   per outer fold: person_id, y, p, SHAP value per feature
  params_r{r}_k{k}.csv     chosen hyperparameters + inner CV score per outer fold
  oof_predictions.csv      person_id, y, p_r0, p_r1, p_r2, p_mean
  shap_values.parquet      all SHAP values (one row per patient per repeat)
The run is RESUMABLE: outer folds that are already saved are skipped.

Run : python nested_cv_xgb.py
      First try N_TRIALS = 5 to check that everything runs, then delete nested_cv/ and use 40.
"""
import glob
import os
import re

import numpy as np
import optuna
from pathlib import Path
import pandas as pd
import xgboost as xgb
from scipy.stats import spearmanr
from sklearn.metrics import roc_auc_score, average_precision_score, brier_score_loss
from sklearn.model_selection import StratifiedKFold

SEED = 42
N_TRIALS = 50  # Optuna trials per outer fold (15 outer folds in total)
N_INNER = 5    # inner CV folds for tuning

HERE = Path(__file__).resolve().parent     # xgb_failure_prediction/
DATA = HERE.parent / "data"                # repo/data (made by data_prep/)
OUT_DIR = HERE / "nested_cv"               # results: patient-level, never commit
ID_COLS = ["person_id", "visit_occurrence_id", "episode_id", "intubation_dt", "extubation_dt",
           "feature_cutoff_dt", "split", "fold", "failure"]
optuna.logging.set_verbosity(optuna.logging.WARNING)   # one line per outer fold instead of per trial
os.makedirs(OUT_DIR, exist_ok=True)

# data + outer folds
df = pd.read_parquet(DATA / "failure_features.parquet")

folds = pd.read_csv(DATA / "nested_folds.csv")


outer_cols = sorted(c for c in folds.columns if c.startswith("outer_r")) # sort column names
#merge on a shared column, left means keep every row of df even if patient not present in split (then use NaN values for split and fold column)
df = df.merge(folds, on="person_id", how="left", validate="one_to_one")  #validate = one_to_one checks that each patient occurs at most once in each table
assert df[outer_cols].notna().all().all(), "run make_split.py first" #ensure all folds are defined
df = df.sort_values("person_id").reset_index(drop=True) # fixed order to ensure same folds even if swl queries return in different order next time
# .reset_index(drop=True) resets row indices/labels 

y = df["failure"].astype(int) # define reintubation failure as int to be real label, column to predict
X = df.drop(columns=[c for c in ID_COLS + outer_cols if c in df.columns]) # drop all identifier and failure columns
# convert text columns (e.g. vent_mode_last) into pandas categories dtype, which XGBoost handles natively
X = X.apply(lambda s: s if pd.api.types.is_numeric_dtype(s) else s.astype("category")) #.apply(function) on table calls the function on each column automatically

#fixed settings for each trial. 
# objective specifies that its solving a binary problem predicted as a probability. Each next tree adds a number to the log-odds
# which then gets converted to a final probability, which is then evaluated with the logloss (BCE). 
# hist specifies to group each feature into at most 256 bins instead of trying each possible split for each feature, reduces compute and approx same results
FIXED = {"objective": "binary:logistic", "eval_metric": "logloss", "tree_method": "hist"}


def dm(X, y=None):
    '''Converts Pandas table into XGBoosts own data format.
    y = None allows for optional label input, since test predictions don't have labels'''
    return xgb.DMatrix(X, label=y, enable_categorical=True)


# inner loop: tuning on one outer training part
def tune(X_tr, y_tr, seed):
    #Define CV splits:
    inner = list(StratifiedKFold(N_INNER, shuffle=True, random_state=seed).split(X_tr, y_tr)) 

    # Tuning (CV on train only)
    # Optuna calls this fcn once per trial, and maximizes the number it returns
    def objective(trial):
        # trial.suggest_float makes Optuna search the paramaters between the bounds. 
        # use log=True when ratio between values matter, where uniform sampling would sample the region where impact is smallest too much
        params = {
            **FIXED,
            "learning_rate":    trial.suggest_float("learning_rate", 0.01, 0.2, log=True), #how much each tree adds to the log-odds: lr x w
            "max_depth":        trial.suggest_int("max_depth", 2, 6), # max path length (feature interactions) in a tree
            "min_child_weight": trial.suggest_float("min_child_weight", 1, 20, log=True), #min weight (approx patients) per leaf
            "subsample":        trial.suggest_float("subsample", 0.5, 1.0), # random fraction of patients each tree sees
            "colsample_bytree": trial.suggest_float("colsample_bytree", 0.5, 1.0), # random fraction of features each tree sees
            "reg_lambda":       trial.suggest_float("reg_lambda", 1e-3, 10, log=True), #L2 penalty: shrinks leaf values by using in the leaf value computation
            "reg_alpha":        trial.suggest_float("reg_alpha", 1e-3, 10, log=True), #L1 penalty: subtract fixed amount of leaf value numerator so becomes 0 if samll
        }
        scores, rounds = [], []
        for step, (tr, va) in enumerate(inner):  # get training and validation positions in each fold
            dtr, dva = dm(X_tr.iloc[tr], y_tr.iloc[tr]), dm(X_tr.iloc[va], y_tr.iloc[va]) # .iloc selects by position, which is what .split() retuned
            #Training for max of 2000 trees, after each new tree compute logloss on val set, early stopping of 50 trees
            bst = xgb.train(params, dtr, num_boost_round=2000, evals=[(dva, "val")], early_stopping_rounds=50, verbose_eval=False)
            #model includes all trees (also last 50 before early stopping) that didn't help, so predict using all trees untill the best one:
            p = bst.predict(dva, iteration_range=(0, bst.best_iteration + 1))
            scores.append(average_precision_score(y_tr.iloc[va], p)) # compute and add val AUPRC 
            rounds.append(bst.best_iteration + 1) # add best number of trees
            trial.report(np.mean(scores), step) # tells Optuna the running mean score after this fold
            if trial.should_prune(): #should_prune() asks whether this trial is doing worse than the median of earlier trials at the same fold
                # if so, raise throws a special exception that ends the function immediately
                # Optuna marks the trial as “pruned”, so the remaining folds of a hopeless trial are skipped
                raise optuna.TrialPruned() 
        # set_user_attr attaches extra information to the trial, which is saved in optuna.db:
        trial.set_user_attr("n_rounds", int(np.mean(rounds)))  #avg number of trees over the 5 folds
        return float(np.mean(scores)) # return CV AUPRC

    study = optuna.create_study(direction="maximize", sampler=optuna.samplers.TPESampler(seed=seed), pruner=optuna.pruners.MedianPruner(n_warmup_steps=2))
    #TPESampler: first 10 trials choose params at random, then seperate trials into "good" (top 10%) and the "others"
    # then, learn two distributions for each param (where "good" values (l(x)) are and where "other" values are (g(x))).
    # At each trial, for each param sample default of 24 values from l(x) and choose the value that maximes l(x)/g(x).
    # Maximing the ratio is equivalent to maximizing the improvement over current best
    # then add new score, update good vs others and their distributions and repeat -> trials concentrate around promising regions
    # Distribitions are bell curve and each trial samples, so still explores nearby possibilities. g(x) in denominator pushes it away
    # from regions that shown to be bad.
    #MedianPruner: only start pruning after 2 folds (and no pruning in first 5 trials by default since no reliable median)

    study.optimize(objective, n_trials=N_TRIALS) #call objective with fresh trial N_TRIALS times
    return study.best_trial # return trial with best CV AUPRC


# outer loop
for col in outer_cols:
    r = int(col.replace("outer_r", "")) #repeat number
    # loop over outer folds (how many times use a different train/test split for one seed)
    for k in range(int(df[col].max()) + 1): 
        path = f"{OUT_DIR}/fold_r{r}_k{k}.parquet"
        if os.path.exists(path):
            print(f"repeat {r} fold {k}: already done, skipped")
            continue
        #obtain train and test sets for this fold in this repeat
        te, tr = df.index[df[col] == k], df.index[df[col] != k]
        seed =  SEED + 100 * r + k   # reproducible seed per outer fold

        # tune best model with CV on this particular train set
        best = tune(X.loc[tr], y.loc[tr], seed)
        # train final model once more on whole training set with best params
        model = xgb.train({**FIXED, "seed": seed, **best.params}, dm(X.loc[tr], y.loc[tr]), num_boost_round=best.user_attrs["n_rounds"])
        model.save_model("xgb_failure_best_model.json")

        d_te = dm(X.loc[te]) 
        p = model.predict(d_te) #predictions on this test set
        contribs = model.predict(d_te, pred_contribs=True)   # performs TreeSHAP: returns shap values; one row per patient and one column per feature, last column = base value

        # Get all shap values with feature names as their column names
        out = pd.DataFrame(contribs[:, :-1], columns=X.columns) 
        out.insert(0, "shap_base", contribs[:, -1]) #add base value as first column (same value everywhere)
        out.insert(0, "p", p) #add test predictions
        out.insert(0, "y", y.loc[te].to_numpy()) #add test labels
        out.insert(0, "outer_fold", k) #add fold
        out.insert(0, "repeat", r) #add repeat
        out.insert(0, "person_id", df.loc[te, "person_id"].to_numpy()) #add person id's
        out.to_parquet(path, index=False) # save to parquet: table of 3,028 rows (patients)
        # save info and best params to a csv file. pd.DataFrame turns a list of dicts into a table with one row per dict
        pd.DataFrame([{"repeat": r, "outer_fold": k, "inner_cv_auprc": best.value, "n_rounds": best.user_attrs["n_rounds"], **best.params}]).to_csv(f"{OUT_DIR}/params_r{r}_k{k}.csv", index=False)
        print(f"repeat {r} fold {k}: inner CV AUPRC {best.value:.3f} | outer AUROC {roc_auc_score(out['y'], p):.3f} (n={len(te)})")

# collect everything
shap_all = pd.concat([pd.read_parquet(f) for f in sorted(glob.glob(f"{OUT_DIR}/fold_r*_k*.parquet"))]) #stack all tables with each 3,028 rows -> r * k * 3,028 rows
shap_all.to_parquet(f"{OUT_DIR}/shap_values.parquet", index=False) 
pd.concat([pd.read_csv(f) for f in sorted(glob.glob(f"{OUT_DIR}/params_r*_k*.csv"))]).to_csv(f"{OUT_DIR}/best_params.csv", index=False) #stack all r*k setting files

# make each patient one row, with a column for each repeat which contains the predicted value, and add p_r to each column name
oof = shap_all.pivot(index="person_id", columns="repeat", values="p").add_prefix("p_r")
oof["p_mean"] = oof.mean(axis=1)  # average of the 3 out-of-fold predictions
#group by patient, take the first y value for each (are the same across the three repeats per patient) -> series with patient_id as index
# then join on oof which als has patient_id as index -> adds y as column and turn patient_id back into column with .reset_index()
oof = oof.join(shap_all.groupby("person_id")["y"].first()).reset_index() 
oof.to_csv(f"{OUT_DIR}/oof_predictions.csv", index=False) #save average oof predictions per patients and true labels as csv

# performance analysis:
yt = oof["y"].to_numpy() #true labels as np array
metrics = [("AUROC", roc_auc_score), ("AUPRC", average_precision_score), ("Brier", brier_score_loss)]
rep_cols = [c for c in oof.columns if re.fullmatch(r"p_r\d+", c)] #find all repeat columns (p_rx)
print(f"Out-of-fold performance on all {len(yt)} patients ({yt.sum()} failures)")
for name, m in metrics: #compute each metric 
    per_rep = [m(yt, oof[c]) for c in rep_cols] #metric for each repeat
    rng = np.random.default_rng(SEED)
    boot = []
    # Compute bootstrap CI for the three metrics to see how much the avg test set score would vary if choose a different test set of same size from this population
    for _ in range(1000):
        i = rng.integers(0, len(yt), len(yt)) #select length y_true patients with replacement
        if yt[i].min() != yt[i].max(): # need both classes for AUROC (else undefined)
            boot.append(m(yt[i], oof["p_mean"].to_numpy()[i])) #compute metric for selected patients and add
    lo, hi = np.percentile(boot, [2.5, 97.5]) #percentiles
    print(f"{name}: per repeat {', '.join(f'{v:.3f}' for v in per_rep)} "
          f"(mean {np.mean(per_rep):.3f}, sd {np.std(per_rep):.3f}) | "
          f"averaged predictions {m(yt, oof['p_mean']):.3f} (95% CI {lo:.3f}-{hi:.3f})")
print(f"no-skill: AUPRC {yt.mean():.3f}, Brier {yt.mean() * (1 - yt.mean()):.3f}")

# first look at SHAP + its stability
feat_cols = list(X.columns) #list all the feature column names (same name if shap values table)
imp = shap_all.groupby("repeat")[feat_cols].apply(lambda s: s.abs().mean())  # get mean abs(SHAP) per feature per repeat
#note that .apply(fcn) after .groupby is independently applied to each group, where then s is each groups table and .mean takes mean by default down columns (axis = 0)

reps = list(imp.index) #list of the row labels (just the repeat numbers)
#compute spearman rho values (monotome, not necesarrily linear relationship) between each pair of not equal repeats:
rhos = [spearmanr(imp.loc[a], imp.loc[b])[0] for i, a in enumerate(reps) for b in reps[i + 1:]] # [0] takes rho vals and ignors p-vals
top10 = [set(imp.loc[a].nlargest(10).index) for a in reps] #top 10 biggest shap values in each repeat
print(f"SHAP stability across repeats: Spearman rank correlation of feature importance "
      f"{', '.join(f'{v:.2f}' for v in rhos)}; features in the top 10 of every repeat: "
      f"{len(set.intersection(*top10))}/10") #which features' shap values are in top 10 in each repeat

# group the 5 summaries of one variable (pco2_last, pco2_mean_6h etc.) into one clinical variable to get overal importance (shap val) of each feature
var = {c: re.sub(r"_(last|mean_6h|min_24h|max_24h|slope_24h)$", "", c) for c in feat_cols} # remove suffixes
#select only the shap values (have feature names), transpose to get features as rows for groupby, then groupby looking up each row label into its group (clinical variable), 
# then sum those rows per group (SHAP values are additive) and transpose back to get patients as rows
per_patient_group = shap_all[feat_cols].T.groupby(var).sum().T   
grouped = per_patient_group.abs().mean().sort_values(ascending=False) # take mean of each absolute shap value across patients, and sort descending to find most important ones.
print("Top 15 clinical variables by mean |SHAP| (log-odds) across pateints, all summaries of a variable combined:")
print(grouped.head(15).round(3).to_string()) # show 15 most important features, .to_string() prints it nicely