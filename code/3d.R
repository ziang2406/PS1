rm(list = ls())

library(data.table)
library(sandwich)

month_number <- function(yyyymm) {
  12L * (yyyymm %/% 100L) + (yyyymm %% 100L)
}

next_yyyymm <- function(yyyymm) {
  year <- yyyymm %/% 100L
  month <- yyyymm %% 100L
  fifelse(month == 12L, (year + 1L) * 100L + 1L, yyyymm + 1L)
}

# -----------------------------------------------------------------------------
# Reconstruct delisting-adjusted returns and market equity in the CRSP master.
# -----------------------------------------------------------------------------

required_crsp_columns <- c(
  "PERMNO", "YYYYMM", "SHRCD", "EXCHCD", "SICCD", "DLSTCD",
  "DLRET", "PRC", "RET", "SHROUT"
)

panel <- fread(
  "cleaned_CRSP.csv",
  select = required_crsp_columns,
  colClasses = list(character = c("RET", "DLRET")),
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(panel, toupper(names(panel)))

stopifnot(
  identical(names(panel), required_crsp_columns),
  !anyNA(panel$PERMNO),
  !anyNA(panel$YYYYMM),
  anyDuplicated(panel, by = c("PERMNO", "YYYYMM")) == 0L,
  all(panel$YYYYMM %% 100L >= 1L & panel$YYYYMM %% 100L <= 12L),
  all(panel$SHRCD %in% c(10L, 11L)),
  all(panel$EXCHCD %in% c(1L, 2L, 3L))
)

panel[, RET_NUMERIC := suppressWarnings(as.numeric(RET))]
panel[, DLRET_NUMERIC := suppressWarnings(as.numeric(DLRET))]

ret_nonnumeric_codes <- sort(unique(
  panel[!is.na(RET) & is.na(RET_NUMERIC), RET]
))
dlret_nonnumeric_codes <- sort(unique(
  panel[!is.na(DLRET) & is.na(DLRET_NUMERIC), DLRET]
))

stopifnot(
  all(ret_nonnumeric_codes %chin% c("B", "C")),
  all(dlret_nonnumeric_codes %chin% c("A", "P", "S", "T"))
)

panel[, RET_ADJ := fcase(
  !is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC),
  (1 + RET_NUMERIC) * (1 + DLRET_NUMERIC) - 1,
  is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC),
  DLRET_NUMERIC,
  !is.na(RET_NUMERIC) & is.na(DLRET_NUMERIC),
  RET_NUMERIC,
  default = NA_real_
)]
panel[, ME := abs(PRC) * SHROUT / 1000]
panel[, MONTH_INDEX := month_number(YYYYMM)]

stopifnot(
  all(is.na(panel$RET_ADJ) | is.finite(panel$RET_ADJ)),
  all(panel$RET_ADJ[!is.na(panel$RET_ADJ)] >= -1),
  all(is.na(panel$ME) | (is.finite(panel$ME) & panel$ME >= 0))
)

# -----------------------------------------------------------------------------
# Left-join GP, BM, RF, and annual duration to the CRSP master panel.
# -----------------------------------------------------------------------------

read_signal <- function(file, expected_value_name) {
  signal <- fread(
    file,
    na.strings = c("", "NA"),
    showProgress = FALSE
  )
  setnames(signal, toupper(names(signal)))
  stopifnot(
    identical(names(signal), c("PERMNO", "YYYYMM", expected_value_name)),
    !anyNA(signal$PERMNO),
    !anyNA(signal$YYYYMM),
    anyDuplicated(signal, by = c("PERMNO", "YYYYMM")) == 0L
  )
  signal
}

gp <- read_signal("GP.csv", "GP")
bmdec <- read_signal("BMdec.csv", "BMDEC")
panel[gp, GP_CZ := i.GP, on = .(PERMNO, YYYYMM)]
panel[bmdec, BM_CZ := i.BMDEC, on = .(PERMNO, YYYYMM)]
rm(gp, bmdec)
invisible(gc())

ff_lines <- readLines("FF.csv", warn = FALSE)
ff_header_line <- which(grepl("^,Mkt-RF,SMB,HML,RF\\r?$", ff_lines))
ff_monthly_lines <- grep("^[[:space:]]*[0-9]{6},", ff_lines, value = TRUE)
stopifnot(length(ff_header_line) >= 1L, length(ff_monthly_lines) > 0L)

ff <- fread(
  text = paste(
    c(ff_lines[ff_header_line[1L]], ff_monthly_lines),
    collapse = "\n"
  ),
  strip.white = TRUE,
  showProgress = FALSE
)
setnames(ff, 1L, "YYYYMM")
setnames(ff, toupper(names(ff)))
ff <- ff[, .(YYYYMM = as.integer(YYYYMM), RF = as.numeric(RF) / 100)]
setorder(ff, YYYYMM)

stopifnot(
  anyDuplicated(ff, by = "YYYYMM") == 0L,
  !anyNA(ff),
  all(diff(month_number(ff$YYYYMM)) == 1L)
)
panel[ff, RF := i.RF, on = "YYYYMM"]
stopifnot(
  !anyNA(panel$RF),
  panel[, uniqueN(RF), by = YYYYMM][, all(V1 == 1L)]
)
rm(ff, ff_lines, ff_monthly_lines)
invisible(gc())

duration <- fread(
  "FirmLevelDur.csv",
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(duration, toupper(names(duration)))
stopifnot(
  identical(names(duration), c("PERMNO", "FF.YEAR", "DUR")),
  !anyNA(duration$PERMNO),
  !anyNA(duration$FF.YEAR),
  anyDuplicated(duration, by = c("PERMNO", "FF.YEAR")) == 0L
)
setnames(duration, "FF.YEAR", "DUR_YEAR")

panel[, DUR_YEAR := YYYYMM %/% 100L - as.integer(YYYYMM %% 100L <= 5L)]
panel[duration, DUR := i.DUR, on = .(PERMNO, DUR_YEAR)]
rm(duration)
invisible(gc())

# -----------------------------------------------------------------------------
# Form within-month continuous percentile ranks using average ranks for ties.
# Each signal uses its own finite cross-section in that month.
# -----------------------------------------------------------------------------

add_percentile_rank <- function(data, signal_column, rank_column) {
  data[
    ,
    (rank_column) := {
      signal <- get(signal_column)
      valid <- is.finite(signal)
      result <- rep(NA_real_, .N)
      result[valid] <- frank(
        signal[valid],
        ties.method = "average",
        na.last = "keep"
      ) / sum(valid)
      result
    },
    by = YYYYMM
  ]
}

add_percentile_rank(panel, "BM_CZ", "Q_BM")
add_percentile_rank(panel, "GP_CZ", "Q_GP")
add_percentile_rank(panel, "DUR", "Q_DUR")

for (rank_column in c("Q_BM", "Q_GP", "Q_DUR")) {
  valid_rank <- panel[[rank_column]][is.finite(panel[[rank_column]])]
  stopifnot(
    length(valid_rank) > 0L,
    all(valid_rank > 0 & valid_rank <= 1)
  )
}

# -----------------------------------------------------------------------------
# Match month-t information to exact next-calendar-month excess stock returns.
# -----------------------------------------------------------------------------

formation_sample <- panel[
  ,
  .(
    PERMNO,
    FORMATION_YYYYMM = YYYYMM,
    FORMATION_INDEX = MONTH_INDEX,
    ME,
    Q_BM,
    Q_GP,
    Q_DUR
  )
]

next_returns <- panel[
  is.finite(RET_ADJ) & is.finite(RF),
  .(
    PERMNO,
    FORMATION_INDEX = MONTH_INDEX - 1L,
    RETURN_YYYYMM = YYYYMM,
    XRET_ADJ = RET_ADJ - RF
  )
]

regression_panel <- merge(
  formation_sample,
  next_returns,
  by = c("PERMNO", "FORMATION_INDEX"),
  all = FALSE,
  sort = FALSE
)
regression_panel <- regression_panel[
  RETURN_YYYYMM >= 197307L & RETURN_YYYYMM <= 202412L
]

stopifnot(
  anyDuplicated(
    regression_panel,
    by = c("PERMNO", "FORMATION_YYYYMM", "RETURN_YYYYMM")
  ) == 0L,
  all(regression_panel$RETURN_YYYYMM ==
    next_yyyymm(regression_panel$FORMATION_YYYYMM)),
  all(is.finite(regression_panel$XRET_ADJ)),
  uniqueN(regression_panel$RETURN_YYYYMM) == 618L,
  min(regression_panel$RETURN_YYYYMM) == 197307L,
  max(regression_panel$RETURN_YYYYMM) == 202412L,
  all(diff(sort(unique(month_number(regression_panel$RETURN_YYYYMM)))) == 1L)
)

rm(formation_sample, next_returns, panel)
invisible(gc())

# -----------------------------------------------------------------------------
# Estimate seven monthly cross-sectional specifications using OLS and WLS.
# -----------------------------------------------------------------------------

model_specifications <- list(
  i = c("Q_BM"),
  ii = c("Q_GP"),
  iii = c("Q_DUR"),
  iv = c("Q_BM", "Q_GP"),
  v = c("Q_DUR", "Q_BM"),
  vi = c("Q_DUR", "Q_GP"),
  vii = c("Q_DUR", "Q_BM", "Q_GP")
)

fit_cross_section <- function(data, regressors, method) {
  design <- cbind(INTERCEPT = 1, as.matrix(data[, ..regressors]))
  response <- data$XRET_ADJ

  if (method == "OLS") {
    fit <- lm.fit(x = design, y = response)
    residuals <- fit$residuals
    rss <- sum(residuals^2)
    tss <- sum((response - mean(response))^2)
    weight_sum <- NA_real_
  } else {
    weights <- data$ME / sum(data$ME)
    stopifnot(abs(sum(weights) - 1) < 1e-12)
    fit <- lm.wfit(x = design, y = response, w = weights)
    residuals <- fit$residuals
    rss <- sum(weights * residuals^2)
    weighted_mean <- sum(weights * response)
    tss <- sum(weights * (response - weighted_mean)^2)
    weight_sum <- sum(weights)
  }

  stopifnot(fit$rank == ncol(design), is.finite(tss), tss > 0)
  estimates <- setNames(rep(NA_real_, 4L), c(
    "INTERCEPT", "B_BM", "B_GP", "B_DUR"
  ))
  coefficient_map <- c(
    INTERCEPT = "INTERCEPT",
    Q_BM = "B_BM",
    Q_GP = "B_GP",
    Q_DUR = "B_DUR"
  )
  estimates[coefficient_map[names(fit$coefficients)]] <- fit$coefficients

  c(
    as.list(estimates),
    list(
      R_SQUARED = 1 - rss / tss,
      N_OBS = nrow(data),
      WEIGHT_SUM = weight_sum
    )
  )
}

monthly_results <- vector("list", length(model_specifications) * 2L)
result_index <- 0L

for (method in c("OLS", "WLS")) {
  for (specification in names(model_specifications)) {
    regressors <- model_specifications[[specification]]
    required_columns <- c("XRET_ADJ", regressors)
    if (method == "WLS") {
      required_columns <- c(required_columns, "ME")
    }

    valid <- regression_panel[
      complete.cases(regression_panel[, ..required_columns]) &
        rowSums(!is.finite(as.matrix(
          regression_panel[, ..required_columns]
        ))) == 0L
    ]
    if (method == "WLS") {
      valid <- valid[ME > 0]
    }

    result_index <- result_index + 1L
    monthly_results[[result_index]] <- valid[
      ,
      fit_cross_section(.SD, regressors, method),
      by = .(FORMATION_YYYYMM, RETURN_YYYYMM)
    ][
      ,
      `:=`(SPECIFICATION = specification, METHOD = method)
    ]
  }
}

monthly_regressions <- rbindlist(monthly_results, use.names = TRUE)
setcolorder(
  monthly_regressions,
  c(
    "METHOD", "SPECIFICATION", "FORMATION_YYYYMM", "RETURN_YYYYMM",
    "INTERCEPT", "B_BM", "B_GP", "B_DUR", "R_SQUARED", "N_OBS",
    "WEIGHT_SUM"
  )
)
setorder(monthly_regressions, METHOD, SPECIFICATION, RETURN_YYYYMM)

stopifnot(
  all(is.finite(monthly_regressions$INTERCEPT)),
  all(is.finite(monthly_regressions$R_SQUARED)),
  all(monthly_regressions$N_OBS > 4L),
  monthly_regressions[
    ,
    all(.N == 618L & min(RETURN_YYYYMM) == 197307L &
      max(RETURN_YYYYMM) == 202412L),
    by = .(METHOD, SPECIFICATION)
  ][, all(V1)],
  monthly_regressions[METHOD == "WLS", all(abs(WEIGHT_SUM - 1) < 1e-12)],
  monthly_regressions[METHOD == "OLS", all(is.na(WEIGHT_SUM))]
)

# -----------------------------------------------------------------------------
# Average monthly coefficients and use Newey-West inference on each time series.
# -----------------------------------------------------------------------------

coefficient_labels <- c(
  INTERCEPT = "Intercept",
  B_BM = "$b_{BM}$",
  B_GP = "$b_{GP}$",
  B_DUR = "$b_{Dur}$"
)

fm_rows <- list()
fm_index <- 0L

for (method in c("OLS", "WLS")) {
  for (specification in names(model_specifications)) {
    specification_data <- monthly_regressions[
      METHOD == method & SPECIFICATION == specification
    ]
    included_coefficients <- c(
      "INTERCEPT",
      unname(c(Q_BM = "B_BM", Q_GP = "B_GP", Q_DUR = "B_DUR")[
        model_specifications[[specification]]
      ])
    )

    for (coefficient_name in included_coefficients) {
      coefficient_series <- specification_data[[coefficient_name]]
      stopifnot(all(is.finite(coefficient_series)))
      constant_model <- lm(coefficient_series ~ 1)
      bandwidth <- bwNeweyWest(
        constant_model,
        kernel = "Bartlett",
        prewhite = FALSE
      )
      lag <- floor(bandwidth)
      covariance <- NeweyWest(
        constant_model,
        lag = lag,
        prewhite = FALSE,
        adjust = FALSE
      )
      estimate <- unname(coef(constant_model)[1L])
      standard_error <- sqrt(covariance[1L, 1L])
      t_statistic <- estimate / standard_error
      p_value <- 2 * pnorm(-abs(t_statistic))

      fm_index <- fm_index + 1L
      fm_rows[[fm_index]] <- data.table(
        METHOD = method,
        SPECIFICATION = specification,
        COEFFICIENT = coefficient_name,
        ESTIMATE = estimate,
        NEWEY_WEST_SE = standard_error,
        T_STATISTIC = t_statistic,
        P_VALUE = p_value,
        SIGNIFICANCE = fifelse(
          p_value < 0.01, "***",
          fifelse(p_value < 0.05, "**", fifelse(p_value < 0.10, "*", ""))
        ),
        NEWEY_WEST_BANDWIDTH = bandwidth,
        NEWEY_WEST_LAG = as.integer(lag),
        T_MONTHS = length(coefficient_series),
        FIRST_RETURN_YYYYMM = min(specification_data$RETURN_YYYYMM),
        LAST_RETURN_YYYYMM = max(specification_data$RETURN_YYYYMM)
      )
    }
  }
}

fm_summary <- rbindlist(fm_rows)
setorder(fm_summary, METHOD, SPECIFICATION, COEFFICIENT)

stopifnot(
  all(is.finite(fm_summary$ESTIMATE)),
  all(is.finite(fm_summary$NEWEY_WEST_SE)),
  all(fm_summary$NEWEY_WEST_SE > 0),
  all(is.finite(fm_summary$T_STATISTIC)),
  all(fm_summary$NEWEY_WEST_LAG >= 0L)
)

fwrite(monthly_regressions, "code/3d_regressions.csv")

# -----------------------------------------------------------------------------
# Write the requested two-panel LaTeX table.
# -----------------------------------------------------------------------------

format_estimate <- function(row) {
  if (nrow(row) == 0L) {
    return("")
  }
  if (nzchar(row$SIGNIFICANCE)) {
    sprintf("$%.4f^{%s}$", row$ESTIMATE, row$SIGNIFICANCE)
  } else {
    sprintf("$%.4f$", row$ESTIMATE)
  }
}

format_t_statistic <- function(row) {
  if (nrow(row) == 0L) {
    return("")
  }
  sprintf("$(%.2f)$", row$T_STATISTIC)
}

latex_lines <- c(
  "\\begin{table}[H]",
  "  \\centering",
  "  \\caption{Fama--MacBeth regressions of monthly stock excess returns}",
  "  \\label{tab:3d}",
  "  \\resizebox{\\textwidth}{!}{%",
  "  \\begin{tabular}{lrrrrrrr}",
  "    \\toprule",
  "    & (i) & (ii) & (iii) & (iv) & (v) & (vi) & (vii) \\\\",
  "    \\midrule"
)

for (method in c("OLS", "WLS")) {
  latex_lines <- c(
    latex_lines,
    sprintf("    \\multicolumn{8}{l}{\\textit{Panel %s: %s}} \\\\",
      ifelse(method == "OLS", "A", "B"), method)
  )

  for (coefficient_name in names(coefficient_labels)) {
    estimates <- character(length(model_specifications))
    t_statistics <- character(length(model_specifications))

    for (spec_index in seq_along(model_specifications)) {
      specification <- names(model_specifications)[spec_index]
      row <- fm_summary[
        METHOD == method &
          SPECIFICATION == specification &
          COEFFICIENT == coefficient_name
      ]
      estimates[spec_index] <- format_estimate(row)
      t_statistics[spec_index] <- format_t_statistic(row)
    }

    latex_lines <- c(
      latex_lines,
      sprintf(
        "    %s & %s \\\\",
        coefficient_labels[[coefficient_name]],
        paste(estimates, collapse = " & ")
      ),
      sprintf(
        "    & %s \\\\",
        paste(t_statistics, collapse = " & ")
      )
    )
  }

  panel_statistics <- monthly_regressions[
    METHOD == method,
    .(
      SPECIFICATION,
      AVERAGE_R_SQUARED = mean(R_SQUARED),
      AVERAGE_N = mean(N_OBS)
    ),
    by = SPECIFICATION
  ]
  average_r_squared <- vapply(
    names(model_specifications),
    function(specification) sprintf(
      "%.3f",
      panel_statistics[SPECIFICATION == specification, AVERAGE_R_SQUARED]
    ),
    character(1L)
  )
  average_n <- vapply(
    names(model_specifications),
    function(specification) sprintf(
      "%.0f",
      panel_statistics[SPECIFICATION == specification, AVERAGE_N]
    ),
    character(1L)
  )
  latex_lines <- c(
    latex_lines,
    sprintf("    Average $R^2$ & %s \\\\", paste(average_r_squared, collapse = " & ")),
    sprintf("    Average $N$ & %s \\\\", paste(average_n, collapse = " & "))
  )

  if (method == "OLS") {
    latex_lines <- c(latex_lines, "    \\midrule")
  }
}

latex_lines <- c(
  latex_lines,
  "    \\bottomrule",
  "  \\end{tabular}%",
  "  }",
  "  \\begin{minipage}{\\textwidth}",
  "  \\footnotesize \\textit{Notes:} Each column reports time-series averages of monthly cross-sectional coefficient estimates. Newey--West $t$-statistics are in parentheses. WLS uses month-$\\tau$ market-equity weights normalized within each valid monthly regression sample. $^{***}$, $^{**}$, and $^{*}$ denote significance at the 1\\%, 5\\%, and 10\\% levels, respectively.",
  "  \\end{minipage}",
  "\\end{table}",
  ""
)

writeLines(latex_lines, "figures/3d.tex", useBytes = TRUE)

print(fm_summary)
