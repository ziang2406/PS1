rm(list = ls())

library(data.table)
library(ggplot2)

month_number <- function(yyyymm) {
  12L * (yyyymm %/% 100L) + (yyyymm %% 100L)
}

yyyymm_to_date <- function(yyyymm) {
  as.Date(sprintf("%06d01", yyyymm), format = "%Y%m%d")
}

descriptive_statistics <- function(x, prefix) {
  x <- x[is.finite(x)]
  stopifnot(length(x) > 0L)

  values <- c(
    observations = length(x),
    mean = mean(x),
    sd = sd(x),
    min = min(x),
    p01 = unname(quantile(x, 0.01)),
    p25 = unname(quantile(x, 0.25)),
    median = median(x),
    p75 = unname(quantile(x, 0.75)),
    p99 = unname(quantile(x, 0.99)),
    max = max(x)
  )

  as.list(setNames(values, paste0(prefix, "_", names(values))))
}

# -----------------------------------------------------------------------------
# Clean the CRSP monthly panel using the student-specified common-stock screen.
# -----------------------------------------------------------------------------

required_crsp_columns <- c(
  "PERMNO",
  "date",
  "SHRCD",
  "EXCHCD",
  "SICCD",
  "DLSTCD",
  "DLRET",
  "PRC",
  "RET",
  "SHROUT"
)

crsp <- fread(
  "CRSP_monthly.csv",
  select = required_crsp_columns,
  na.strings = c("", "NA"),
  showProgress = FALSE
)

stopifnot(identical(names(crsp), required_crsp_columns))

crsp_raw_observations <- nrow(crsp)
crsp_raw_permnos <- uniqueN(crsp$PERMNO)
crsp_raw_start_yyyymm <- min(crsp$date, na.rm = TRUE) %/% 100L
crsp_raw_end_yyyymm <- max(crsp$date, na.rm = TRUE) %/% 100L

crsp[, SICCD_numeric := suppressWarnings(as.integer(SICCD))]
siccd_nonnumeric_codes <- sort(unique(
  crsp[!is.na(SICCD) & is.na(SICCD_numeric), SICCD]
))

stopifnot(
  identical(siccd_nonnumeric_codes, "Z"),
  all(crsp$date %% 100L >= 1L & crsp$date %% 100L <= 31L)
)

crsp[, date := date %/% 100L]
setnames(crsp, "date", "YYYYMM")

cleaned_crsp <- crsp[
  !is.na(PERMNO) &
    !is.na(YYYYMM) &
    !is.na(SHRCD) &
    !is.na(EXCHCD) &
    !is.na(SICCD_numeric) &
    SHRCD %in% c(10L, 11L) &
    EXCHCD %in% c(1L, 2L, 3L) &
    !(SICCD_numeric >= 4900L & SICCD_numeric <= 4949L) &
    !(SICCD_numeric >= 6000L & SICCD_numeric <= 6999L)
]

cleaned_crsp[, SICCD := SICCD_numeric]
cleaned_crsp[, SICCD_numeric := NULL]
setcolorder(
  cleaned_crsp,
  c(
    "PERMNO",
    "YYYYMM",
    "SHRCD",
    "EXCHCD",
    "SICCD",
    "DLSTCD",
    "DLRET",
    "PRC",
    "RET",
    "SHROUT"
  )
)
setorder(cleaned_crsp, PERMNO, YYYYMM)

rm(crsp)
invisible(gc())

stopifnot(
  anyDuplicated(cleaned_crsp, by = c("PERMNO", "YYYYMM")) == 0L,
  all(cleaned_crsp$YYYYMM %% 100L >= 1L &
    cleaned_crsp$YYYYMM %% 100L <= 12L)
)

cleaned_crsp_observations <- nrow(cleaned_crsp)
cleaned_crsp_permnos <- uniqueN(cleaned_crsp$PERMNO)
cleaned_crsp_start_yyyymm <- min(cleaned_crsp$YYYYMM)
cleaned_crsp_end_yyyymm <- max(cleaned_crsp$YYYYMM)

# -----------------------------------------------------------------------------
# Select one valid CCM link per GVKEY-FYEAR and construct annual book equity.
# -----------------------------------------------------------------------------

fundamental <- fread(
  "Fundamental Annual.csv",
  colClasses = list(
    character = c("GVKEY", "LINKDT", "LINKENDDT")
  ),
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(fundamental, toupper(names(fundamental)))

required_fundamental_columns <- c(
  "GVKEY",
  "LINKPRIM",
  "LINKTYPE",
  "LPERMNO",
  "LINKDT",
  "LINKENDDT",
  "DATADATE",
  "FYEAR",
  "INDFMT",
  "CONSOL",
  "POPSRC",
  "DATAFMT",
  "AT",
  "CEQ",
  "LT",
  "PSTK",
  "PSTKL",
  "PSTKRV",
  "SEQ",
  "TXDITC"
)
stopifnot(all(required_fundamental_columns %in% names(fundamental)))

fundamental_raw_observations <- nrow(fundamental)

fundamental <- fundamental[
  INDFMT == "INDL" &
    DATAFMT == "STD" &
    POPSRC == "D" &
    CONSOL == "C"
]
fundamental_standard_filter_observations <- nrow(fundamental)

standard_duplicate_keys <- fundamental[
  ,
  .N,
  by = .(GVKEY, FYEAR)
][N > 1L]

fundamental[, LINKDT_numeric := suppressWarnings(as.integer(LINKDT))]
fundamental[, LINKENDDT_numeric := suppressWarnings(as.integer(LINKENDDT))]

linkend_nonnumeric_codes <- sort(unique(
  fundamental[
    !is.na(LINKENDDT) & is.na(LINKENDDT_numeric),
    LINKENDDT
  ]
))

stopifnot(
  length(linkend_nonnumeric_codes) == 1L,
  identical(linkend_nonnumeric_codes, "E")
)

fundamental <- fundamental[
  LINKTYPE %chin% c("LC", "LU") &
    LINKPRIM %chin% c("P", "C") &
    !is.na(LPERMNO) &
    !is.na(DATADATE) &
    !is.na(LINKDT_numeric) &
    LINKDT_numeric <= DATADATE &
    (
      is.na(LINKENDDT) |
        LINKENDDT == "E" |
        (!is.na(LINKENDDT_numeric) & DATADATE <= LINKENDDT_numeric)
    )
]

fundamental_valid_link_observations <- nrow(fundamental)

# Distinguish accounting duplicates (different DATADATE values) from multiple
# CCM security links attached to the same accounting statement.
accounting_duplicate_keys <- fundamental[
  ,
  .(
    rows = .N,
    distinct_DATADATEs = uniqueN(DATADATE)
  ),
  by = .(GVKEY, FYEAR)
][distinct_DATADATEs > 1L]

accounting_duplicate_records <- fundamental[
  accounting_duplicate_keys,
  on = .(GVKEY, FYEAR),
  nomatch = 0L,
  .(
    GVKEY,
    FYEAR,
    DATADATE,
    LPERMNO,
    LINKPRIM,
    LINKTYPE,
    LINKDT,
    LINKENDDT,
    SEQ,
    CEQ,
    PSTK,
    AT,
    LT,
    TXDITC
  )
]
setorder(accounting_duplicate_records, GVKEY, FYEAR, DATADATE)

# The revision supersedes the initial halt rule: retain the latest DATADATE,
# then prefer P to C and LC to LU.
latest_statement_dates <- fundamental[
  ,
  .(DATADATE = max(DATADATE)),
  by = .(GVKEY, FYEAR)
]
fundamental <- fundamental[
  latest_statement_dates,
  on = .(GVKEY, FYEAR, DATADATE),
  nomatch = 0L
]

fundamental[, LINKPRIM_rank := fifelse(LINKPRIM == "P", 1L, 2L)]
fundamental[, LINKTYPE_rank := fifelse(LINKTYPE == "LC", 1L, 2L)]

best_linkprim <- fundamental[
  ,
  .(LINKPRIM_rank = min(LINKPRIM_rank)),
  by = .(GVKEY, FYEAR)
]
fundamental <- fundamental[
  best_linkprim,
  on = .(GVKEY, FYEAR, LINKPRIM_rank),
  nomatch = 0L
]

best_linktype <- fundamental[
  ,
  .(LINKTYPE_rank = min(LINKTYPE_rank)),
  by = .(GVKEY, FYEAR)
]
fundamental <- fundamental[
  best_linktype,
  on = .(GVKEY, FYEAR, LINKTYPE_rank),
  nomatch = 0L
]

residual_link_ties <- fundamental[
  ,
  .(
    rows = .N,
    distinct_LPERMNOs = uniqueN(LPERMNO)
  ),
  by = .(GVKEY, FYEAR)
][distinct_LPERMNOs > 1L]

stopifnot(nrow(residual_link_ties) == 0L)

setorder(
  fundamental,
  GVKEY,
  FYEAR,
  DATADATE,
  LINKPRIM_rank,
  LINKTYPE_rank,
  LPERMNO
)
fundamental <- fundamental[
  !duplicated(fundamental, by = c("GVKEY", "FYEAR"))
]

stopifnot(
  anyDuplicated(fundamental, by = c("GVKEY", "FYEAR")) == 0L
)

selected_link_observations <- nrow(fundamental)
missing_fyear_observations <- sum(is.na(fundamental$FYEAR))
fundamental <- fundamental[!is.na(FYEAR)]

# "First available" for a composite requires every component of that
# candidate to be observed. The revised prompt sets BVPS to zero only when all
# three preferred-stock measures are unavailable.
fundamental[
  ,
  CEQ_plus_PSTK := fifelse(
    !is.na(CEQ) & !is.na(PSTK),
    CEQ + PSTK,
    NA_real_
  )
]
fundamental[
  ,
  AT_minus_LT := fifelse(
    !is.na(AT) & !is.na(LT),
    AT - LT,
    NA_real_
  )
]
fundamental[, SE := fcoalesce(SEQ, CEQ_plus_PSTK, AT_minus_LT)]
fundamental[, TXDITC_used := fcoalesce(TXDITC, 0)]
fundamental[, BVPS := fcoalesce(PSTKRV, PSTKL, PSTK)]
fundamental[is.na(BVPS), BVPS := 0]
fundamental[, BE := SE + TXDITC_used - BVPS]

setorder(fundamental, GVKEY, FYEAR, DATADATE)
fundamental[, annual_observation_number := seq_len(.N), by = GVKEY]

third_or_later_observations <- fundamental[
  annual_observation_number >= 3L,
  .N
]

fundamental_be <- fundamental[
  annual_observation_number >= 3L &
    !is.na(BE) &
    is.finite(BE) &
    BE > 0
]

positive_be_observations <- nrow(fundamental_be)
positive_be_gvkeys <- uniqueN(fundamental_be$GVKEY)

# The revised specification says that a valid CCM link alone assigns LPERMNO;
# no exact DATADATE-month CRSP merge is applied.
fundamental_be[, BM_YEAR := FYEAR + 1L]

# -----------------------------------------------------------------------------
# Match book equity to December market equity and resolve inverse link clashes.
# -----------------------------------------------------------------------------

december_me <- cleaned_crsp[
  YYYYMM %% 100L == 12L,
  .(
    PERMNO,
    FYEAR = YYYYMM %/% 100L,
    BM_YEAR = YYYYMM %/% 100L + 1L,
    ME = abs(PRC) * SHROUT / 1000
  )
]

stopifnot(
  anyDuplicated(december_me, by = c("PERMNO", "FYEAR")) == 0L
)

december_me_observations <- nrow(december_me)
finite_positive_december_me_observations <- december_me[
  is.finite(ME) & ME > 0,
  .N
]

annual_signal_candidates <- merge(
  fundamental_be,
  december_me[, .(PERMNO, BM_YEAR, ME)],
  by.x = c("LPERMNO", "BM_YEAR"),
  by.y = c("PERMNO", "BM_YEAR"),
  all = FALSE,
  sort = FALSE
)
annual_signal_candidates[, BM := BE / ME]

annual_signal_matched_observations <- nrow(annual_signal_candidates)
annual_signal_candidates <- annual_signal_candidates[
  is.finite(BM) & BM > 0
]
annual_signal_positive_observations <- nrow(annual_signal_candidates)

competing_signal_keys <- annual_signal_candidates[
  ,
  .N,
  by = .(PERMNO = LPERMNO, BM_YEAR)
][N > 1L]

competing_signal_records <- annual_signal_candidates[
  competing_signal_keys,
  on = .(LPERMNO = PERMNO, BM_YEAR),
  nomatch = 0L,
  .(
    PERMNO = LPERMNO,
    BM_YEAR,
    GVKEY,
    FYEAR,
    DATADATE,
    LINKPRIM,
    LINKTYPE,
    LINKPRIM_rank,
    LINKTYPE_rank,
    BE,
    ME,
    BM
  )
]
setorder(
  competing_signal_records,
  PERMNO,
  BM_YEAR,
  LINKPRIM_rank,
  LINKTYPE_rank,
  -DATADATE
)

annual_signal_candidates[
  ,
  formation_date := BM_YEAR * 10000L + 630L
]

stopifnot(
  all(competing_signal_records$DATADATE <=
    competing_signal_records$BM_YEAR * 10000L + 630L)
)

setorder(
  annual_signal_candidates,
  LPERMNO,
  BM_YEAR,
  LINKPRIM_rank,
  LINKTYPE_rank,
  -DATADATE,
  GVKEY
)

top_signal_candidates <- annual_signal_candidates[
  ,
  .SD[
    LINKPRIM_rank == min(LINKPRIM_rank) &
      LINKTYPE_rank == min(
        LINKTYPE_rank[LINKPRIM_rank == min(LINKPRIM_rank)]
      )
  ][DATADATE == max(DATADATE)],
  by = .(LPERMNO, BM_YEAR)
]

unresolved_signal_ties <- top_signal_candidates[
  ,
  .N,
  by = .(LPERMNO, BM_YEAR)
][N > 1L]

stopifnot(nrow(unresolved_signal_ties) == 0L)

annual_signals <- top_signal_candidates[
  ,
  .(
    PERMNO = LPERMNO,
    BM_YEAR,
    GVKEY,
    FYEAR,
    DATADATE,
    LINKPRIM,
    LINKTYPE,
    annual_observation_number,
    BE,
    ME,
    BM
  )
]
setorder(annual_signals, PERMNO, BM_YEAR)

stopifnot(
  anyDuplicated(annual_signals, by = c("PERMNO", "BM_YEAR")) == 0L
)

annual_signal_observations <- nrow(annual_signals)
annual_signal_permnos <- uniqueN(annual_signals$PERMNO)
annual_signal_start_year <- min(annual_signals$BM_YEAR)
annual_signal_end_year <- max(annual_signals$BM_YEAR)

# Carry each June signal through the following May.
cleaned_crsp[
  ,
  BM_YEAR := YYYYMM %/% 100L - fifelse(YYYYMM %% 100L < 6L, 1L, 0L)
]

monthly_bm <- merge(
  cleaned_crsp[, .(PERMNO, YYYYMM, BM_YEAR)],
  annual_signals[, .(PERMNO, BM_YEAR, BM)],
  by = c("PERMNO", "BM_YEAR"),
  all = FALSE,
  sort = TRUE
)

stopifnot(
  anyDuplicated(monthly_bm, by = c("PERMNO", "YYYYMM")) == 0L,
  all(is.finite(monthly_bm$BM)),
  all(monthly_bm$BM > 0)
)

monthly_bm_observations <- nrow(monthly_bm)
monthly_bm_permnos <- uniqueN(monthly_bm$PERMNO)
monthly_bm_start_yyyymm <- min(monthly_bm$YYYYMM)
monthly_bm_end_yyyymm <- max(monthly_bm$YYYYMM)

# -----------------------------------------------------------------------------
# Compare the constructed signal to the Chen-Zimmermann BMdec level.
# -----------------------------------------------------------------------------

bmdec <- fread(
  "BMdec.csv",
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(bmdec, toupper(names(bmdec)))

stopifnot(
  identical(names(bmdec), c("PERMNO", "YYYYMM", "BMDEC")),
  anyDuplicated(bmdec, by = c("PERMNO", "YYYYMM")) == 0L,
  !anyNA(bmdec$PERMNO),
  !anyNA(bmdec$YYYYMM)
)

bmdec[, BM_CZ := BMDEC]

bmdec_observations <- nrow(bmdec)
bmdec_permnos <- uniqueN(bmdec$PERMNO)
bmdec_start_yyyymm <- min(bmdec$YYYYMM)
bmdec_end_yyyymm <- max(bmdec$YYYYMM)

joint_unrestricted <- merge(
  monthly_bm[, .(PERMNO, YYYYMM, BM)],
  bmdec[, .(PERMNO, YYYYMM, BM_CZ)],
  by = c("PERMNO", "YYYYMM"),
  all = FALSE,
  sort = TRUE
)

joint_inner_observations <- nrow(joint_unrestricted)
joint_nonpositive_or_nonfinite_observations <- joint_unrestricted[
  !is.finite(BM) |
    BM <= 0 |
    !is.finite(BM_CZ) |
    BM_CZ <= 0,
  .N
]

regression_sample <- joint_unrestricted[
  is.finite(BM) &
    BM > 0 &
    is.finite(BM_CZ) &
    BM_CZ > 0
]

rm(bmdec, joint_unrestricted)
invisible(gc())

joint_observations <- nrow(regression_sample)
joint_permnos <- uniqueN(regression_sample$PERMNO)
joint_start_yyyymm <- min(regression_sample$YYYYMM)
joint_end_yyyymm <- max(regression_sample$YYYYMM)
bm_bmcz_correlation <- cor(regression_sample$BM, regression_sample$BM_CZ)
bm_bmcz_median_ratio <- median(
  regression_sample$BM_CZ / regression_sample$BM
)

# Run the requested monthly cross-sectional regressions.
monthly_regressions <- regression_sample[
  ,
  {
    X <- cbind(1, BM)
    model <- lm.fit(x = X, y = BM_CZ)
    total_sum_squares <- sum((BM_CZ - mean(BM_CZ))^2)
    residual_sum_squares <- sum(model$residuals^2)

    stopifnot(
      .N >= 3L,
      model$rank == 2L,
      total_sum_squares > 0
    )

    .(
      a_tau = unname(model$coefficients[1]),
      b_tau = unname(model$coefficients[2]),
      R_squared = 1 - residual_sum_squares / total_sum_squares,
      N_tau = .N
    )
  },
  by = YYYYMM
]

setorder(monthly_regressions, YYYYMM)
monthly_regressions[, month := yyyymm_to_date(YYYYMM)]
setcolorder(
  monthly_regressions,
  c("YYYYMM", "month", "a_tau", "b_tau", "R_squared", "N_tau")
)

regression_month_index <- month_number(monthly_regressions$YYYYMM)

stopifnot(
  all(diff(regression_month_index) == 1L),
  all(is.finite(monthly_regressions$a_tau)),
  all(is.finite(monthly_regressions$b_tau)),
  all(is.finite(monthly_regressions$R_squared)),
  all(monthly_regressions$R_squared >= -1e-12),
  all(monthly_regressions$R_squared <= 1 + 1e-12),
  all(monthly_regressions$N_tau >= 3L)
)

# Aggregate requested construction, matching, level, and regression summaries.
summary_values <- c(
  list(
    crsp_raw_observations = crsp_raw_observations,
    crsp_raw_permnos = crsp_raw_permnos,
    crsp_raw_start_YYYYMM = crsp_raw_start_yyyymm,
    crsp_raw_end_YYYYMM = crsp_raw_end_yyyymm,
    cleaned_crsp_observations = cleaned_crsp_observations,
    cleaned_crsp_permnos = cleaned_crsp_permnos,
    cleaned_crsp_start_YYYYMM = cleaned_crsp_start_yyyymm,
    cleaned_crsp_end_YYYYMM = cleaned_crsp_end_yyyymm,
    fundamental_raw_observations = fundamental_raw_observations,
    fundamental_standard_filter_observations =
      fundamental_standard_filter_observations,
    standard_duplicate_GVKEY_FYEAR_pairs = nrow(standard_duplicate_keys),
    fundamental_valid_link_observations =
      fundamental_valid_link_observations,
    accounting_duplicate_GVKEY_FYEAR_pairs =
      nrow(accounting_duplicate_keys),
    accounting_duplicate_rows = nrow(accounting_duplicate_records),
    residual_link_tie_pairs = nrow(residual_link_ties),
    selected_link_observations = selected_link_observations,
    selected_link_missing_FYEAR_observations = missing_fyear_observations,
    third_or_later_observations = third_or_later_observations,
    positive_BE_observations = positive_be_observations,
    positive_BE_GVKEYs = positive_be_gvkeys,
    december_ME_observations = december_me_observations,
    finite_positive_december_ME_observations =
      finite_positive_december_me_observations,
    annual_signal_matched_observations =
      annual_signal_matched_observations,
    annual_signal_positive_observations =
      annual_signal_positive_observations,
    competing_PERMNO_BM_YEAR_pairs = nrow(competing_signal_keys),
    competing_signal_rows = nrow(competing_signal_records),
    unresolved_signal_tie_pairs = nrow(unresolved_signal_ties),
    annual_signal_observations = annual_signal_observations,
    annual_signal_permnos = annual_signal_permnos,
    annual_signal_start_BM_YEAR = annual_signal_start_year,
    annual_signal_end_BM_YEAR = annual_signal_end_year,
    monthly_BM_observations = monthly_bm_observations,
    monthly_BM_permnos = monthly_bm_permnos,
    monthly_BM_start_YYYYMM = monthly_bm_start_yyyymm,
    monthly_BM_end_YYYYMM = monthly_bm_end_yyyymm,
    BMdec_observations = bmdec_observations,
    BMdec_permnos = bmdec_permnos,
    BMdec_start_YYYYMM = bmdec_start_yyyymm,
    BMdec_end_YYYYMM = bmdec_end_yyyymm,
    joint_inner_observations = joint_inner_observations,
    joint_nonpositive_or_nonfinite_observations =
      joint_nonpositive_or_nonfinite_observations,
    joint_positive_finite_observations = joint_observations,
    joint_permnos = joint_permnos,
    joint_start_YYYYMM = joint_start_yyyymm,
    joint_end_YYYYMM = joint_end_yyyymm,
    BM_BM_CZ_correlation = bm_bmcz_correlation,
    BM_CZ_to_BM_median_ratio = bm_bmcz_median_ratio,
    regression_months = nrow(monthly_regressions),
    monthly_N_min = min(monthly_regressions$N_tau),
    monthly_N_mean = mean(monthly_regressions$N_tau),
    monthly_N_median = median(monthly_regressions$N_tau),
    monthly_N_max = max(monthly_regressions$N_tau),
    mean_a_tau = mean(monthly_regressions$a_tau),
    mean_b_tau = mean(monthly_regressions$b_tau),
    mean_R_squared = mean(monthly_regressions$R_squared)
  ),
  descriptive_statistics(fundamental_be$BE, "BE"),
  descriptive_statistics(
    december_me[is.finite(ME) & ME > 0, ME],
    "December_ME"
  ),
  descriptive_statistics(annual_signals$BM, "annual_BM"),
  descriptive_statistics(regression_sample$BM, "joint_BM"),
  descriptive_statistics(regression_sample$BM_CZ, "joint_BM_CZ")
)

summary_statistics <- as.data.table(summary_values)

# Save the requested data products only after all structural checks pass.
dir.create("code", showWarnings = FALSE, recursive = TRUE)
dir.create("figures", showWarnings = FALSE, recursive = TRUE)

fwrite(cleaned_crsp, "cleaned_CRSP.csv")
fwrite(monthly_regressions, "code/3b_regressions.csv")
fwrite(summary_statistics, "code/3b_summary.csv")

# Match the established Question 3a plotting style.
first_plot_year <- (joint_start_yyyymm %/% 100L + 4L) %/% 5L * 5L
last_plot_year <- (joint_end_yyyymm %/% 100L + 4L) %/% 5L * 5L
date_breaks <- seq.Date(
  as.Date(sprintf("%04d-01-01", first_plot_year)),
  as.Date(sprintf("%04d-01-01", last_plot_year)),
  by = "5 years"
)

save_time_series_plot <- function(
  data,
  variable,
  y_label,
  title,
  filename
) {
  plot <- ggplot(
    data,
    aes(x = month, y = .data[[variable]])
  ) +
    geom_hline(yintercept = 0, linetype = "dashed") +
    geom_line(color = "red", linewidth = 0.8) +
    scale_x_date(
      breaks = date_breaks,
      date_labels = "%Y",
      limits = range(data$month)
    ) +
    labs(
      x = "Years",
      y = y_label,
      title = title
    ) +
    theme_classic() +
    theme(
      text = element_text(family = "Times New Roman", size = 14),
      plot.title = element_text(hjust = 0.5)
    )

  ggsave(
    filename = filename,
    plot = plot,
    width = 8,
    height = 5,
    dpi = 300,
    bg = "white"
  )
}

save_time_series_plot(
  monthly_regressions,
  "b_tau",
  expression(hat(b)[tau]),
  "Monthly cross-sectional book-to-market slopes",
  "figures/3b_slope.png"
)

save_time_series_plot(
  monthly_regressions,
  "a_tau",
  expression(hat(a)[tau]),
  "Monthly cross-sectional book-to-market intercepts",
  "figures/3b_intercept.png"
)

save_time_series_plot(
  monthly_regressions,
  "R_squared",
  expression(R^2),
  "Monthly cross-sectional book-to-market R-squared",
  "figures/3b_Rsquared.png"
)

cat("Accounting duplicates (reported before the latest-DATADATE rule):\n")
print(accounting_duplicate_records)
cat("Competing PERMNO-BM_YEAR signals (reported before ranking):\n")
print(competing_signal_records)
cat("Aggregate summary statistics:\n")
print(summary_statistics)
cat("Monthly cross-sectional regressions:\n")
print(monthly_regressions)
