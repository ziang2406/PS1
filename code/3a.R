rm(list = ls())
library(data.table)
library(ggplot2)

month_number <- function(yyyymm) {
  12L * (yyyymm %/% 100L) + (yyyymm %% 100L)
}

yyyymm_to_date <- function(yyyymm) {
  as.Date(sprintf("%06d01", yyyymm), format = "%Y%m%d")
}

# Read only the CRSP fields needed by the student-authored specification.
required_crsp_columns <- c(
  "PERMNO",
  "date",
  "SHRCD",
  "EXCHCD",
  "SICCD",
  "DLSTCD",
  "DLRET",
  "RET"
)

crsp <- fread(
  "CRSP_monthly.csv",
  select = required_crsp_columns,
  na.strings = c("", "NA"),
  showProgress = FALSE
)

stopifnot(all(required_crsp_columns %in% names(crsp)))

crsp_raw_observations <- nrow(crsp)
crsp_raw_permnos <- uniqueN(crsp$PERMNO)
crsp_raw_start_yyyymm <- min(crsp$date, na.rm = TRUE) %/% 100L
crsp_raw_end_yyyymm <- max(crsp$date, na.rm = TRUE) %/% 100L

# CRSP character status codes mean that the associated numeric value is
# unavailable. Treat them as missing rather than imputing a return or SIC code.
crsp[, SICCD_numeric := suppressWarnings(as.integer(SICCD))]
crsp[, RET_numeric := suppressWarnings(as.numeric(RET))]
crsp[, DLRET_numeric := suppressWarnings(as.numeric(DLRET))]

ret_nonnumeric_codes <- sort(unique(
  crsp[!is.na(RET) & is.na(RET_numeric), RET]
))
dlret_nonnumeric_codes <- sort(unique(
  crsp[!is.na(DLRET) & is.na(DLRET_numeric), DLRET]
))
siccd_nonnumeric_codes <- sort(unique(
  crsp[!is.na(SICCD) & is.na(SICCD_numeric), SICCD]
))

stopifnot(
  identical(ret_nonnumeric_codes, c("B", "C")),
  identical(dlret_nonnumeric_codes, c("A", "P", "S", "T")),
  identical(siccd_nonnumeric_codes, "Z"),
  all(crsp$date %% 100L >= 1L & crsp$date %% 100L <= 31L)
)

crsp[, date := date %/% 100L]
setnames(crsp, "date", "YYYYMM")

stopifnot(
  all(crsp$YYYYMM %% 100L >= 1L & crsp$YYYYMM %% 100L <= 12L),
  crsp_raw_start_yyyymm == 196206L,
  crsp_raw_end_yyyymm == 202412L
)

# Restrict to the requested common-stock universe with observed selection fields.
crsp_sample <- crsp[
  !is.na(PERMNO) &
    !is.na(YYYYMM) &
    !is.na(SHRCD) &
    !is.na(EXCHCD) &
    !is.na(SICCD_numeric) &
    SHRCD %in% c(10L, 11L) &
    EXCHCD %in% c(1L, 2L, 3L) &
    !(SICCD_numeric >= 4900L & SICCD_numeric <= 4949L) &
    !(SICCD_numeric >= 6000L & SICCD_numeric <= 6999L),
  .(
    PERMNO,
    YYYYMM,
    SHRCD,
    EXCHCD,
    SICCD = SICCD_numeric,
    DLSTCD,
    RET = RET_numeric,
    DLRET = DLRET_numeric,
    RET_was_nonnumeric = !is.na(RET) & is.na(RET_numeric),
    DLRET_was_nonnumeric = !is.na(DLRET) & is.na(DLRET_numeric)
  )
]

rm(crsp)
invisible(gc())

setorder(crsp_sample, PERMNO, YYYYMM)

stopifnot(
  anyDuplicated(
    crsp_sample,
    by = c("PERMNO", "YYYYMM")
  ) == 0L,
  all(crsp_sample[
    ,
    all(diff(YYYYMM) > 0L),
    by = PERMNO
  ]$V1),
  min(crsp_sample$YYYYMM) == 196206L,
  max(crsp_sample$YYYYMM) == 202412L
)

# Apply the four requested adjusted-return cases.
crsp_sample[, return_availability := fcase(
  !is.na(RET) & !is.na(DLRET), "RET and DLRET",
  is.na(RET) & !is.na(DLRET), "DLRET only",
  !is.na(RET) & is.na(DLRET), "RET only",
  default = "RET and DLRET missing"
)]

crsp_sample[, RET_ADJ := fcase(
  return_availability == "RET and DLRET",
  (1 + RET) * (1 + DLRET) - 1,
  return_availability == "DLRET only",
  DLRET,
  return_availability == "RET only",
  RET,
  default = NA_real_
)]

availability_counts <- crsp_sample[
  ,
  .N,
  by = return_availability
]

availability_count <- function(case_name) {
  value <- availability_counts[
    return_availability == case_name,
    N
  ]
  if (length(value) == 0L) 0L else as.integer(value)
}

ret_and_dlret_observations <- availability_count("RET and DLRET")
dlret_only_observations <- availability_count("DLRET only")
ret_only_observations <- availability_count("RET only")
ret_and_dlret_missing_observations <- availability_count(
  "RET and DLRET missing"
)

stopifnot(
  all(is.na(crsp_sample$RET_ADJ) | is.finite(crsp_sample$RET_ADJ)),
  all(crsp_sample$RET_ADJ[!is.na(crsp_sample$RET_ADJ)] >= -1),
  ret_and_dlret_observations +
    dlret_only_observations +
    ret_only_observations +
    ret_and_dlret_missing_observations == nrow(crsp_sample)
)

# Verify that no finite adjusted return appears after a delisting month.
dlstcd_observations <- sum(!is.na(crsp_sample$DLSTCD))
dlstcd_permnos <- uniqueN(crsp_sample[!is.na(DLSTCD), PERMNO])

crsp_sample[
  ,
  first_delisting_month := {
    delisting_months <- YYYYMM[!is.na(DLSTCD)]
    if (length(delisting_months) == 0L) {
      NA_integer_
    } else {
      min(delisting_months)
    }
  },
  by = PERMNO
]

post_delisting_ret_adj_observations <- crsp_sample[
  !is.na(first_delisting_month) &
    YYYYMM > first_delisting_month &
    !is.na(RET_ADJ),
  .N
]

stopifnot(post_delisting_ret_adj_observations == 0L)
crsp_sample[, first_delisting_month := NULL]

# Construct MOM using exactly the prior 12 calendar months.
crsp_sample[, month_index := month_number(YYYYMM)]
crsp_sample[, prior_ret_adj := shift(RET_ADJ, 1L), by = PERMNO]
crsp_sample[
  ,
  window_start_month_index := shift(month_index, 12L),
  by = PERMNO
]
crsp_sample[
  ,
  prior_12_missing := frollsum(
    as.integer(is.na(prior_ret_adj)),
    n = 12L,
    align = "right",
    na.rm = FALSE
  ),
  by = PERMNO
]
crsp_sample[
  ,
  prior_12_zero_gross := frollsum(
    as.integer(!is.na(prior_ret_adj) & prior_ret_adj == -1),
    n = 12L,
    align = "right",
    na.rm = FALSE
  ),
  by = PERMNO
]
crsp_sample[
  ,
  prior_12_log_gross := frollsum(
    fifelse(
      is.na(prior_ret_adj) | prior_ret_adj == -1,
      0,
      log1p(prior_ret_adj)
    ),
    n = 12L,
    align = "right",
    na.rm = FALSE
  ),
  by = PERMNO
]

crsp_sample[
  ,
  complete_12_month_window :=
    !is.na(window_start_month_index) &
    month_index - window_start_month_index == 12L &
    prior_12_missing == 0
]

crsp_sample[
  ,
  MOM := fcase(
    !complete_12_month_window,
    NA_real_,
    prior_12_zero_gross > 0,
    -1,
    default = expm1(prior_12_log_gross)
  )
]

crsp_sample[
  ,
  c(
    "month_index",
    "prior_ret_adj",
    "window_start_month_index",
    "prior_12_missing",
    "prior_12_zero_gross",
    "prior_12_log_gross",
    "complete_12_month_window"
  ) := NULL
]

mom_available_observations <- sum(!is.na(crsp_sample$MOM))
mom_missing_observations <- sum(is.na(crsp_sample$MOM))

stopifnot(
  all(is.finite(crsp_sample$MOM[!is.na(crsp_sample$MOM)])),
  all(crsp_sample$MOM[!is.na(crsp_sample$MOM)] >= -1),
  min(crsp_sample[!is.na(MOM), YYYYMM]) == 196306L,
  max(crsp_sample[!is.na(MOM), YYYYMM]) == 202412L,
  mom_available_observations + mom_missing_observations ==
    nrow(crsp_sample)
)

# Load the Chen-Zimmermann momentum signal and standardize its names.
cz <- fread(
  "Mom12m.csv",
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(cz, toupper(names(cz)))

stopifnot(
  identical(names(cz), c("PERMNO", "YYYYMM", "MOM12M")),
  !anyNA(cz$PERMNO),
  !anyNA(cz$YYYYMM),
  !anyNA(cz$MOM12M),
  anyDuplicated(cz, by = c("PERMNO", "YYYYMM")) == 0L,
  all(cz$YYYYMM %% 100L >= 1L & cz$YYYYMM %% 100L <= 12L)
)

cz_observations <- nrow(cz)
cz_permnos <- uniqueN(cz$PERMNO)
cz_start_yyyymm <- min(cz$YYYYMM)
cz_end_yyyymm <- max(cz$YYYYMM)

cz[, MOM_CZ := MOM12M]

# Inner match on the two keys, retaining missing MOM only for diagnostics.
matched <- merge(
  crsp_sample[, .(PERMNO, YYYYMM, MOM)],
  cz[, .(PERMNO, YYYYMM, MOM_CZ)],
  by = c("PERMNO", "YYYYMM"),
  all = FALSE,
  sort = TRUE
)

inner_matched_observations <- nrow(matched)
inner_matched_permnos <- uniqueN(matched$PERMNO)
inner_matched_start_yyyymm <- min(matched$YYYYMM)
inner_matched_end_yyyymm <- max(matched$YYYYMM)
inner_matched_missing_mom <- sum(is.na(matched$MOM))

regression_sample <- matched[
  YYYYMM >= 196306L &
    YYYYMM <= 202412L &
    !is.na(MOM) &
    !is.na(MOM_CZ)
]

rm(cz, matched)
invisible(gc())

stopifnot(
  all(is.finite(regression_sample$MOM)),
  all(is.finite(regression_sample$MOM_CZ)),
  min(regression_sample$YYYYMM) == 196306L,
  max(regression_sample$YYYYMM) == 202412L,
  cor(regression_sample$MOM, regression_sample$MOM_CZ) > 0.9
)

# Run one cross-sectional OLS regression per calendar month.
monthly_regressions <- regression_sample[
  ,
  {
    X <- cbind(1, MOM)
    model <- lm.fit(x = X, y = MOM_CZ)
    total_sum_squares <- sum((MOM_CZ - mean(MOM_CZ))^2)
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
  nrow(monthly_regressions) == 739L,
  monthly_regressions$YYYYMM[1] == 196306L,
  monthly_regressions$YYYYMM[nrow(monthly_regressions)] == 202412L,
  all(diff(regression_month_index) == 1L),
  all(is.finite(monthly_regressions$a_tau)),
  all(is.finite(monthly_regressions$b_tau)),
  all(is.finite(monthly_regressions$R_squared)),
  all(monthly_regressions$R_squared >= -1e-12),
  all(monthly_regressions$R_squared <= 1 + 1e-12),
  all(monthly_regressions$N_tau >= 3L),
  abs(monthly_regressions$a_tau[1] - 0.1134289795314972) < 1e-12,
  abs(monthly_regressions$b_tau[1] - 1.0224261373263140) < 1e-12,
  abs(monthly_regressions$R_squared[1] -
    0.9040545328898818) < 1e-12,
  monthly_regressions$N_tau[1] == 926L,
  abs(monthly_regressions$a_tau[739] -
    (-0.05568425539888505)) < 1e-12,
  abs(monthly_regressions$b_tau[739] -
    0.6802334524488500) < 1e-12,
  abs(monthly_regressions$R_squared[739] -
    0.9098617445564168) < 1e-12,
  monthly_regressions$N_tau[739] == 3040L
)

restricted_crsp_observations <- nrow(crsp_sample)
restricted_crsp_permnos <- uniqueN(crsp_sample$PERMNO)
restricted_crsp_start_yyyymm <- min(crsp_sample$YYYYMM)
restricted_crsp_end_yyyymm <- max(crsp_sample$YYYYMM)
complete_case_regression_observations <- nrow(regression_sample)
complete_case_regression_permnos <- uniqueN(regression_sample$PERMNO)
matched_start_yyyymm <- min(regression_sample$YYYYMM)
matched_end_yyyymm <- max(regression_sample$YYYYMM)
mom_cz_correlation <- cor(regression_sample$MOM, regression_sample$MOM_CZ)
mom_cz_mean_absolute_difference <- mean(
  abs(regression_sample$MOM - regression_sample$MOM_CZ)
)

summary_statistics <- data.table(
  crsp_raw_observations = crsp_raw_observations,
  crsp_raw_permnos = crsp_raw_permnos,
  crsp_raw_start_YYYYMM = crsp_raw_start_yyyymm,
  crsp_raw_end_YYYYMM = crsp_raw_end_yyyymm,
  restricted_crsp_observations = restricted_crsp_observations,
  restricted_crsp_permnos = restricted_crsp_permnos,
  restricted_crsp_start_YYYYMM = restricted_crsp_start_yyyymm,
  restricted_crsp_end_YYYYMM = restricted_crsp_end_yyyymm,
  ret_and_dlret_observations = ret_and_dlret_observations,
  dlret_only_observations = dlret_only_observations,
  ret_only_observations = ret_only_observations,
  ret_and_dlret_missing_observations =
    ret_and_dlret_missing_observations,
  ret_nonnumeric_unavailable_observations =
    sum(crsp_sample$RET_was_nonnumeric),
  dlret_nonnumeric_unavailable_observations =
    sum(crsp_sample$DLRET_was_nonnumeric),
  dlstcd_observations = dlstcd_observations,
  dlstcd_permnos = dlstcd_permnos,
  post_delisting_ret_adj_observations =
    post_delisting_ret_adj_observations,
  mom_available_observations = mom_available_observations,
  mom_missing_observations = mom_missing_observations,
  cz_observations = cz_observations,
  cz_permnos = cz_permnos,
  cz_start_YYYYMM = cz_start_yyyymm,
  cz_end_YYYYMM = cz_end_yyyymm,
  inner_matched_observations = inner_matched_observations,
  inner_matched_permnos = inner_matched_permnos,
  inner_matched_start_YYYYMM = inner_matched_start_yyyymm,
  inner_matched_end_YYYYMM = inner_matched_end_yyyymm,
  inner_matched_missing_mom = inner_matched_missing_mom,
  complete_case_regression_observations =
    complete_case_regression_observations,
  complete_case_regression_permnos = complete_case_regression_permnos,
  matched_start_YYYYMM = matched_start_yyyymm,
  matched_end_YYYYMM = matched_end_yyyymm,
  regression_months = nrow(monthly_regressions),
  monthly_N_min = min(monthly_regressions$N_tau),
  monthly_N_mean = mean(monthly_regressions$N_tau),
  monthly_N_median = median(monthly_regressions$N_tau),
  monthly_N_max = max(monthly_regressions$N_tau),
  mean_a_tau = mean(monthly_regressions$a_tau),
  mean_b_tau = mean(monthly_regressions$b_tau),
  mean_R_squared = mean(monthly_regressions$R_squared),
  mom_cz_correlation = mom_cz_correlation,
  mom_cz_mean_absolute_difference = mom_cz_mean_absolute_difference
)

stopifnot(
  crsp_raw_observations == 4775098L,
  crsp_raw_permnos == 38325L,
  restricted_crsp_observations == 2752659L,
  restricted_crsp_permnos == 21793L,
  ret_and_dlret_observations == 1608L,
  dlret_only_observations == 16105L,
  ret_only_observations == 2696618L,
  ret_and_dlret_missing_observations == 38328L,
  dlstcd_observations == 21023L,
  dlstcd_permnos == 21023L,
  mom_available_observations == 2426965L,
  mom_missing_observations == 325694L,
  cz_observations == 3715128L,
  cz_permnos == 28065L,
  cz_start_yyyymm == 192611L,
  cz_end_yyyymm == 202412L,
  inner_matched_observations == 2500601L,
  inner_matched_missing_mom == 90109L,
  complete_case_regression_observations == 2410492L,
  nrow(monthly_regressions) == 739L,
  min(monthly_regressions$N_tau) == 926L,
  median(monthly_regressions$N_tau) == 3337L,
  max(monthly_regressions$N_tau) == 5206L,
  abs(mean(monthly_regressions$N_tau) - 3261.829499323410) < 1e-10,
  abs(mean(monthly_regressions$a_tau) -
    0.007786592469) < 1e-10,
  abs(mean(monthly_regressions$b_tau) -
    0.8928906394) < 1e-10,
  abs(mean(monthly_regressions$R_squared) -
    0.8910553640) < 1e-10
)

dir.create("code", showWarnings = FALSE, recursive = TRUE)
fwrite(monthly_regressions, "code/3a_regressions.csv")
fwrite(summary_statistics, "code/3a_summary.csv")

# Produce the three requested time-series plots in the established format.
date_breaks <- seq.Date(
  as.Date("1965-01-01"),
  as.Date("2025-01-01"),
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

dir.create("figures", showWarnings = FALSE, recursive = TRUE)

save_time_series_plot(
  monthly_regressions,
  "b_tau",
  expression(hat(b)[tau]),
  "Monthly cross-sectional momentum slopes",
  "figures/3a_slope.png"
)

save_time_series_plot(
  monthly_regressions,
  "a_tau",
  expression(hat(a)[tau]),
  "Monthly cross-sectional momentum intercepts",
  "figures/3a_intercept.png"
)

save_time_series_plot(
  monthly_regressions,
  "R_squared",
  expression(R^2),
  "Monthly cross-sectional momentum R-squared",
  "figures/3a_Rsquared.png"
)

print(summary_statistics)
print(monthly_regressions)
