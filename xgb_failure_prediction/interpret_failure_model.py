"""
Performance + interpretability figures for the nested-CV XGBoost failure model.

Run after nested_cv_xgb.py (same folder). It re-fits the 15 outer models from
nested_cv/best_params.csv (fast: no tuning), checks they reproduce the saved predictions,
and writes presentation-ready figures to figures/:

  fig1_performance.png    ROC, precision-recall and calibration (out-of-fold, all patients)
  fig2_shap_importance.png  mean |SHAP| per clinical variable, one dot per repeat (stability)
  fig3_shap_beeswarm.png  top 15 individual features: SHAP per patient, coloured by feature value
  fig4_dependence_ale.png SHAP dependence + ALE curves for guideline variables, with literature thresholds
  fig5_permutation.png    permutation importance per clinical variable on held-out folds (AUROC drop)
  fig6_waterfall.png      two example patients: what drove their prediction
and the numbers behind them as figures/interp_*.csv.

Run: python interpret_failure_model.py     (takes a few minutes)
"""
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import xgboost as xgb
from matplotlib.colors import LinearSegmentedColormap
from scipy.stats import spearmanr
from sklearn.calibration import calibration_curve
from sklearn.metrics import average_precision_score, precision_recall_curve, roc_auc_score, roc_curve

SEED = 42
OUT_DIR, FIG_DIR = "nested_cv", "figures"
ID_COLS = ["person_id", "visit_occurrence_id", "episode_id", "intubation_dt", "extubation_dt",
           "feature_cutoff_dt", "split", "fold", "failure"]
HP_NAMES = ["learning_rate", "max_depth", "min_child_weight", "subsample", "colsample_bytree",
            "reg_lambda", "reg_alpha"]
FIXED = {"objective": "binary:logistic", "eval_metric": "logloss", "tree_method": "hist"}
SUFFIX = r"_(last|mean_6h|min_24h|max_24h|slope_24h)$"
N_ALE_BINS, N_PERM = 10, 3

# guideline variables for the dependence / ALE figure: feature -> (axis label, thresholds, note)
# Sources: MacIntyre et al., Chest 2001 (ACCP/AARC/ACCCM weaning guideline: Recommendation 2 and Table 3);
#          Boles et al., Eur Respir J 2007 (international weaning consensus: readiness and SBT-failure criteria);
#          Yang & Tobin, N Engl J Med 1991 (RSBI); Mokhlesi et al., Respir Care 2007 (PaCO2 >= 44 mmHg).
GUIDE = {
    "peep_set_last":    ("PEEP set (cmH2O)", [8], "readiness: PEEP ≤ 5-8 (MacIntyre 2001)"),
    "fio2_set_last":    ("FiO2 set (fraction)", [0.4, 0.5], "readiness: FiO2 ≤ 0.4–0.5 (MacIntyre 2001)"),
    "pf_ratio_last":    ("P/F ratio (mmHg)", [150, 200], "readiness: P/F ≥ 150–200 (MacIntyre 2001)"),
    "rsbi_mean_6h":     ("RSBI, mean last 6 h", [105], "readiness: RSBI < 105 (Boles 2007)"),
    "pco2_last":        ("pCO2 (mmHg)", [44], "risk: PaCO2 ≥ 44 (Mokhlesi 2007)"),
    "heart_rate_last":  ("Heart rate (/min)", [140], "readiness: HR ≤ 140  (Boles 2007)"),
    "temperature_last": ("Temperature (°C)", [38], "trial entry: T ≤ 38 °C (MacIntyre 2001)"),
    "gcs_em_last":      ("GCS eye + motor", [], "no E+M threshold: guidelines use total GCS"),
}

# ---------------------------------------------------------------- chart style (light, for slides)
TEXT, TEXT2, MUTED, GRID = "#0b0b0b", "#52514e", "#8f8e8a", "#e6e5e1"
BLUE, ORANGE, RED, POINT = "#2a78d6", "#eb6834", "#e34948", "#b3b2ad"
SEQ = LinearSegmentedColormap.from_list("seq_blue", ["#cde2fb", "#86b6ef", "#2a78d6", "#184f95", "#0d366b"])
plt.rcParams.update({
    "font.size": 11, "axes.titlesize": 12, "axes.titleweight": "bold", "axes.labelcolor": TEXT,
    "axes.edgecolor": MUTED, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "xtick.color": TEXT2, "ytick.color": TEXT2, "legend.frameon": False,
    "savefig.dpi": 200, "savefig.bbox": "tight", "figure.facecolor": "white",
})
os.makedirs(FIG_DIR, exist_ok=True)


def save(fig, name):
    fig.savefig(f"{FIG_DIR}/{name}")
    plt.close(fig)
    print(f"  saved {FIG_DIR}/{name}")


def dm(X, y=None):
    return xgb.DMatrix(X, label=y, enable_categorical=True)


def boot_ci(metric, y_true, p, n=1000):
    rng = np.random.default_rng(SEED)
    vals = []
    for _ in range(n):
        i = rng.integers(0, len(y_true), len(y_true))
        if y_true[i].min() != y_true[i].max():
            vals.append(metric(y_true[i], p[i]))
    return np.percentile(vals, [2.5, 97.5])


# ---------------------------------------------------------------- data (built exactly as in nested_cv_xgb.py)
df = pd.read_parquet("failure_features.parquet").drop(columns=["died_without_reintubation"], errors="ignore")
folds = pd.read_csv("nested_folds.csv")
outer_cols = sorted(c for c in folds.columns if c.startswith("outer_r"))
df = (df.merge(folds, on="person_id", how="left", validate="one_to_one")
        .sort_values("person_id").reset_index(drop=True))
y = df["failure"].astype(int)
X = df.drop(columns=[c for c in ID_COLS + outer_cols if c in df.columns])
X = X.apply(lambda s: s if pd.api.types.is_numeric_dtype(s) else s.astype("category"))
feat_cols = list(X.columns)
group_of = {c: re.sub(SUFFIX, "", c) for c in feat_cols}
members = {g: [c for c in feat_cols if group_of[c] == g] for g in sorted(set(group_of.values()))}

shap_all = pd.read_parquet(f"{OUT_DIR}/shap_values.parquet")
oof = pd.read_csv(f"{OUT_DIR}/oof_predictions.csv")
params = pd.read_csv(f"{OUT_DIR}/best_params.csv")
assert set(feat_cols) <= set(shap_all.columns), "features differ from the nested CV run: rerun nested_cv_xgb.py"


def grouped(sh):
    """Per-patient SHAP per clinical variable: add up the summaries of one variable."""
    return sh[feat_cols].T.groupby(group_of).sum().T


# ---------------------------------------------------------------- re-fit the 15 outer models
print("Re-fitting the outer models from best_params.csv ...")
models, max_diff = [], 0.0
for row in params.itertuples(index=False):
    r, k = int(row.repeat), int(row.outer_fold)
    tr, te = df.index[df[f"outer_r{r}"] != k], df.index[df[f"outer_r{r}"] == k]
    hp = {h: getattr(row, h) for h in HP_NAMES}
    hp["max_depth"] = int(hp["max_depth"])
    m = xgb.train({**FIXED, "seed": SEED + 100 * r + k, **hp}, dm(X.loc[tr], y.loc[tr]),
                  num_boost_round=int(row.n_rounds))
    saved = shap_all.loc[(shap_all["repeat"] == r) & (shap_all["outer_fold"] == k)].set_index("person_id")["p"]
    p_new = m.predict(dm(X.loc[te]))
    max_diff = max(max_diff, float(np.abs(p_new - saved.loc[df.loc[te, "person_id"]].to_numpy()).max()))
    models.append((r, k, m, te))
print(f"  {len(models)} models; largest difference with the saved predictions: {max_diff:.1e}"
      + ("" if max_diff < 1e-4 else "  (small numerical differences: the figures still describe the same procedure)"))

# ---------------------------------------------------------------- fig 1: performance
print("Figure 1: performance")
yt, pm = oof["y"].to_numpy(), oof["p_mean"].to_numpy()
auc, ap = roc_auc_score(yt, pm), average_precision_score(yt, pm)
auc_ci, ap_ci = boot_ci(roc_auc_score, yt, pm), boot_ci(average_precision_score, yt, pm)
fig, axes = plt.subplots(1, 3, figsize=(14, 4.4))

fpr, tpr, _ = roc_curve(yt, pm)
ax = axes[0]
ax.plot([0, 1], [0, 1], ls="--", lw=1, color=MUTED, label="chance (0.5)")
ax.plot(fpr, tpr, lw=2, color=BLUE, label=f"XGBoost {auc:.3f} ({auc_ci[0]:.3f}–{auc_ci[1]:.3f})")
ax.set(title="ROC curve", xlabel="1 − specificity", ylabel="sensitivity", xlim=(0, 1), ylim=(0, 1))
ax.legend(loc="lower right", fontsize=9)

prec, rec, _ = precision_recall_curve(yt, pm)
ax = axes[1]
ax.axhline(yt.mean(), ls="--", lw=1, color=MUTED, label=f"no skill ({yt.mean():.3f})")
ax.plot(rec, prec, lw=2, color=BLUE, label=f"XGBoost {ap:.3f} ({ap_ci[0]:.3f}–{ap_ci[1]:.3f})")
ax.set(title="Precision-recall curve", xlabel="recall (sensitivity)", ylabel="precision (PPV)",
       xlim=(0, 1), ylim=(0, 1))
ax.legend(loc="upper right", fontsize=9)

frac, mean_p = calibration_curve(yt, pm, n_bins=10, strategy="quantile")
top = max(frac.max(), mean_p.max()) * 1.15
ax = axes[2]
ax.plot([0, top], [0, top], ls="--", lw=1, color=MUTED, label="perfect calibration")
ax.plot(mean_p, frac, lw=2, marker="o", ms=6, color=BLUE, label="XGBoost (deciles of risk)")
ax.set(title="Calibration", xlabel="predicted risk", ylabel="observed failure rate", xlim=(0, top), ylim=(0, top))
ax.legend(loc="upper left", fontsize=9)
fig.suptitle(f"Out-of-fold performance, {len(yt)} extubations ({yt.sum()} failures), "
             "averaged over 3 repeats of 5-fold nested CV", fontsize=11, color=TEXT2, y=1.02)
save(fig, "fig1_performance.png")

# ---------------------------------------------------------------- fig 2: grouped SHAP importance per repeat
print("Figure 2: SHAP importance per clinical variable")
imp = pd.DataFrame({f"repeat_{r}": grouped(g).abs().mean() for r, g in shap_all.groupby("repeat")})
imp["mean"] = imp.mean(axis=1)
imp["n_features"] = [len(members[g]) for g in imp.index]
imp = imp.sort_values("mean", ascending=False)
imp.to_csv(f"{FIG_DIR}/interp_importance_grouped.csv")
top15 = imp.head(15).iloc[::-1]
rep_cols = [c for c in imp.columns if c.startswith("repeat_")]
fig, ax = plt.subplots(figsize=(7.5, 6))
ypos = np.arange(len(top15))
ax.barh(ypos, top15["mean"], height=0.62, color=BLUE, label="mean over 3 repeats")
for j, c in enumerate(rep_cols):
    ax.scatter(top15[c], ypos, s=18, color=TEXT, zorder=3, label="each repeat" if j == 0 else None)
ax.set_yticks(ypos, [f"{g}  ({n})" for g, n in zip(top15.index, top15["n_features"])])
ax.grid(axis="y", visible=False)
ax.set(xlabel="mean |SHAP| (log-odds)", title="Which clinical variables drive the predictions?")
ax.legend(loc="lower right", fontsize=9)
ax.text(0, -0.16, "(n) = number of features summed into the variable (last, mean, min, max, slope)",
        transform=ax.transAxes, fontsize=8.5, color=TEXT2)
save(fig, "fig2_shap_importance.png")

# ---------------------------------------------------------------- fig 3: beeswarm of the top 15 individual features
print("Figure 3: SHAP beeswarm")
r0 = shap_all["repeat"].min()
s0 = shap_all[shap_all["repeat"] == r0].set_index("person_id")
vals = df.set_index("person_id").loc[s0.index]
order = list(shap_all[feat_cols].abs().mean().sort_values(ascending=False).head(15).index[::-1])
rng = np.random.default_rng(SEED)
fig, ax = plt.subplots(figsize=(8.5, 6.5))
for i, f in enumerate(order):
    phi = s0[f].to_numpy()
    jitter = i + rng.uniform(-0.32, 0.32, len(phi))
    v = vals[f]
    if pd.api.types.is_numeric_dtype(v):
        pct = v.rank(pct=True).to_numpy()
        miss = np.isnan(pct)
        ax.scatter(phi[miss], jitter[miss], s=5, color=POINT, alpha=0.5, linewidths=0)
        ax.scatter(phi[~miss], jitter[~miss], s=5, c=SEQ(pct[~miss]), alpha=0.75, linewidths=0)
    else:
        ax.scatter(phi, jitter, s=5, color=POINT, alpha=0.5, linewidths=0)
ax.axvline(0, color=MUTED, lw=1)
ax.set_yticks(range(len(order)), order)
ax.grid(axis="y", visible=False)
ax.set(xlabel="SHAP value (effect on log-odds of failure)",
       title="Top 15 features: effect per patient, coloured by the feature's value")
sm = plt.cm.ScalarMappable(cmap=SEQ)
cb = fig.colorbar(sm, ax=ax, fraction=0.03, pad=0.02, ticks=[0, 1])
cb.ax.set_yticklabels(["low", "high"])
cb.set_label("feature value (grey = missing)", color=TEXT2)
cb.outline.set_visible(False)
save(fig, "fig3_shap_beeswarm.png")


# ---------------------------------------------------------------- fig 4: SHAP dependence + ALE for guideline variables
def ale(model, Xte, f, edges):
    """Accumulated local effect of feature f (log-odds) on the bin edges, from the held-out patients."""
    Xo = Xte[Xte[f].notna()]
    if len(Xo) == 0:
        return None
    n_bins = len(edges) - 1
    b = np.clip(np.searchsorted(edges, Xo[f].to_numpy(), side="left"), 1, n_bins) - 1
    lo, hi = Xo.copy(), Xo.copy()
    lo[f], hi[f] = edges[b], edges[b + 1]
    d = model.predict(dm(hi), output_margin=True) - model.predict(dm(lo), output_margin=True)
    counts = np.bincount(b, minlength=n_bins)
    mean_d = np.divide(np.bincount(b, weights=d, minlength=n_bins), counts,
                       out=np.zeros(n_bins), where=counts > 0)
    curve = np.concatenate([[0.0], np.cumsum(mean_d)])
    centres = (curve[:-1] + curve[1:]) / 2
    return curve - np.sum(centres * counts) / counts.sum()          # centred: average effect 0


print("Figure 4: dependence + ALE")
phi_mean = shap_all.groupby("person_id")[feat_cols].mean()          # per patient, averaged over repeats
guide = [f for f in GUIDE if f in X.columns and pd.api.types.is_numeric_dtype(X[f]) and X[f].notna().sum() > 50]
ale_rows = []
ncols = min(4, len(guide))
nrows = int(np.ceil(len(guide) / ncols))
fig, axes = plt.subplots(nrows, ncols, figsize=(4 * ncols, 3.4 * nrows), squeeze=False)
for ax, f in zip(axes.flat, guide):
    label, thresholds, note = GUIDE[f]
    x = df.set_index("person_id").loc[phi_mean.index, f]
    ok = x.notna()
    ax.scatter(x[ok], phi_mean.loc[ok, f], s=4, color=POINT, alpha=0.35, linewidths=0,
               label="SHAP, per patient")
    edges = np.unique(np.quantile(X[f].dropna(), np.linspace(0, 1, N_ALE_BINS + 1)))
    if len(edges) >= 3:
        curves = [c for c in (ale(m, X.loc[te], f, edges) for _, _, m, te in models) if c is not None]
        curves = np.vstack(curves)
        ax.fill_between(edges, curves.min(0), curves.max(0), color=ORANGE, alpha=0.15, linewidths=0,
                        label="ALE, range over 15 models")
        ax.plot(edges, curves.mean(0), color=ORANGE, lw=2, label="ALE, mean of 15 models")
        ale_rows += [{"feature": f, "x": e, "ale_mean": a, "ale_min": lo_, "ale_max": hi_}
                     for e, a, lo_, hi_ in zip(edges, curves.mean(0), curves.min(0), curves.max(0))]
    for t in thresholds:
        ax.axvline(t, ls="--", lw=1.2, color=TEXT2, label="literature threshold" if t == thresholds[0] else None)
    ax.axhline(0, color=MUTED, lw=0.8)
    lo_x, hi_x = np.nanpercentile(X[f], [1, 99])
    if thresholds:                                   # always keep the threshold lines in view
        lo_x, hi_x = min(lo_x, min(thresholds)), max(hi_x, max(thresholds))
    margin = (hi_x - lo_x) * 0.03
    ax.set_xlim(lo_x - margin, hi_x + margin)
    ax.set(title=label, xlabel=note if note else "", ylabel="effect on log-odds")
    ax.xaxis.label.set_color(TEXT2)
    ax.xaxis.label.set_size(8)
for ax in list(axes.flat)[len(guide):]:
    ax.set_visible(False)
handles, labels = axes.flat[0].get_legend_handles_labels()
fig.legend(handles, labels, loc="lower center", ncol=4, bbox_to_anchor=(0.5, -0.04), fontsize=9.5,
           markerscale=4)
fig.suptitle("Does the model's risk bend where the guidelines say it should?", fontsize=13,
             fontweight="bold", y=1.01)
fig.tight_layout()
save(fig, "fig4_dependence_ale.png")
pd.DataFrame(ale_rows).to_csv(f"{FIG_DIR}/interp_ale.csv", index=False)

# ---------------------------------------------------------------- fig 5: grouped permutation importance (held-out)
print("Figure 5: permutation importance (a few minutes)")
rows = []
for r, k, m, te in models:
    Xte, yte = X.loc[te], y.loc[te].to_numpy()
    base = roc_auc_score(yte, m.predict(dm(Xte)))
    rng = np.random.default_rng(SEED + 100 * r + k)
    for g, cols in members.items():
        drops = []
        for _ in range(N_PERM):
            perm = rng.permutation(len(Xte))
            Xp = Xte.copy()
            for c in cols:                                   # shuffle all summaries of a variable together
                Xp[c] = Xte[c].iloc[perm].set_axis(Xte.index)
            drops.append(base - roc_auc_score(yte, m.predict(dm(Xp))))
        rows.append({"repeat": r, "outer_fold": k, "variable": g, "auroc_drop": np.mean(drops)})
perm_df = pd.DataFrame(rows)
perm_sum = perm_df.groupby("variable")["auroc_drop"].agg(["mean", "std"]).sort_values("mean", ascending=False)
perm_sum.to_csv(f"{FIG_DIR}/interp_permutation.csv")
top15p = perm_sum.head(15).iloc[::-1]
fig, ax = plt.subplots(figsize=(7.5, 6))
ypos = np.arange(len(top15p))
ax.barh(ypos, top15p["mean"], height=0.62, color=BLUE)
ax.errorbar(top15p["mean"], ypos, xerr=top15p["std"], fmt="none", ecolor=TEXT2, elinewidth=1, capsize=2)
ax.axvline(0, color=MUTED, lw=1)
ax.set_yticks(ypos, top15p.index)
ax.grid(axis="y", visible=False)
ax.set(xlabel="drop in AUROC when the variable is shuffled\n(mean ± SD over the 15 held-out folds)",
       title="Permutation importance per clinical variable")
save(fig, "fig5_permutation.png")
common = imp.index.intersection(perm_sum.index)
rho = spearmanr(imp.loc[common, "mean"], perm_sum.loc[common, "mean"])[0]


# ---------------------------------------------------------------- fig 6: two example patients (waterfall)
def waterfall(ax, pid, name):
    contrib = grouped(s0.loc[[pid]]).iloc[0]
    order_ = contrib.abs().sort_values(ascending=False).index
    shown, rest = list(order_[:8]), order_[8:]
    items = [(g, contrib[g]) for g in shown] + [(f"other {len(rest)} variables", contrib[rest].sum())]
    start = s0.loc[pid, "shap_base"]
    left, ypos_ = start, np.arange(len(items))[::-1]
    path = [start] + list(start + np.cumsum([v for _, v in items]))
    pad = (max(path) - min(path)) * 0.15 + 0.02          # room for the value labels
    for (g, v), yy in zip(items, ypos_):
        ax.barh(yy, v, left=left, height=0.6, color=RED if v > 0 else BLUE)
        if abs(v) >= 0.005:
            ax.text(left + v + (pad / 8 if v > 0 else -pad / 8), yy, f"{v:+.2f}", va="center",
                    ha="left" if v > 0 else "right", fontsize=9, color=TEXT)
        left += v
    ax.set_xlim(min(path) - pad, max(path) + pad)
    raw = df.set_index("person_id").loc[pid]

    def lab(g):
        f = g if g in raw.index else f"{g}_last"
        if f in raw.index and pd.api.types.is_number(raw[f]) and pd.notna(raw[f]):
            return f"{g} = {raw[f]:.3g}"
        return g
    ax.set_yticks(ypos_, [lab(g) for g, _ in items])
    ax.axvline(start, color=MUTED, lw=1, ls="--")
    ax.grid(axis="y", visible=False)
    p_base, p_pat = 1 / (1 + np.exp(-start)), s0.loc[pid, "p"]
    outcome = "reintubated" if s0.loc[pid, "y"] == 1 else "not reintubated"
    ax.set(xlabel="log-odds of failure", title=f"{name}: predicted risk {p_pat:.0%} "
           f"(average {p_base:.0%}), outcome: {outcome}")
    return {"patient": name, "person_id": pid, "p": p_pat, **{g: v for g, v in items}}


print("Figure 6: example patients")
pid_hi = s0["p"][s0["y"] == 1].idxmax()      # highest predicted risk among patients who failed
pid_lo = s0["p"][s0["y"] == 0].idxmin()      # lowest predicted risk among patients who did not
fig, axes = plt.subplots(1, 2, figsize=(15, 4.8))
ex = [waterfall(axes[0], pid_hi, "Patient A"), waterfall(axes[1], pid_lo, "Patient B")]
fig.text(0.5, -0.03, "Red pushes the risk up, blue pushes it down; bars start at the model's average "
         "prediction (dashed line). Values are the last measurement before extubation.",
         ha="center", fontsize=9, color=TEXT2)
fig.tight_layout()
save(fig, "fig6_waterfall.png")
pd.DataFrame(ex).to_csv(f"{FIG_DIR}/interp_examples.csv", index=False)

# ---------------------------------------------------------------- summary
print(f"\nAUROC {auc:.3f} ({auc_ci[0]:.3f}-{auc_ci[1]:.3f}) | AUPRC {ap:.3f} ({ap_ci[0]:.3f}-{ap_ci[1]:.3f})")
print(f"Agreement between SHAP and permutation importance rankings (Spearman): {rho:.2f}")
print("Top 10 by permutation importance (AUROC drop):")
print(perm_sum.head(10).round(4).to_string())