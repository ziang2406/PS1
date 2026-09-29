rm(list = ls())

library(data.table)
library(sandwich)
library(plm)

month_number <- function(yyyymm) {
  12L * (yyyymm %/% 100L) + (yyyymm %% 100L)
}

next_yyyymm <- function(yyyymm) {
  year <- yyyymm %/% 100L
  month <- yyyymm %% 100L
  fifelse(month == 12L, (year + 1L) * 100L + 1L, yyyymm + 1L)
}

breakpoint_names <- paste0("P", seq(10L, 90L, by = 10L))
breakpoint_probabilities <- seq(0.1, 0.9, by = 0.1)

# -----------------------------------------------------------------------------
# Reconstruct the 3d master panel: adjusted returns, ME, signals, RF, and DUR.
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
  all(panel$SHRCD %in% c(10L, 11L)),
  all(panel$EXCHCD %in% c(1L, 2L, 3L))
)

panel[, RET_NUMERIC := suppressWarnings(as.numeric(RET))]
panel[, DLRET_NUMERIC := suppressWarnings(as.numeric(DLRET))]
stopifnot(
  all(sort(unique(panel[!is.na(RET) & is.na(RET_NUMERIC), RET])) %chin%
    c("B", "C")),
  all(sort(unique(panel[!is.na(DLRET) & is.na(DLRET_NUMERIC), DLRET])) %chin%
    c("A", "P", "S", "T"))
)

panel[, RET_ADJ := fcase(
  !is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC),
  (1 + RET_NUMERIC) * (1 + DLRET_NUMERIC) - 1,
  is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC), DLRET_NUMERIC,
  !is.na(RET_NUMERIC) & is.na(DLRET_NUMERIC), RET_NUMERIC,
  default = NA_real_
)]
panel[, `:=`(
  ME = abs(PRC) * SHROUT / 1000,
  MONTH_INDEX = month_number(YYYYMM)
)]
stopifnot(
  all(is.na(panel$RET_ADJ) | is.finite(panel$RET_ADJ)),
  all(panel$RET_ADJ[!is.na(panel$RET_ADJ)] >= -1),
  all(is.na(panel$ME) | (is.finite(panel$ME) & panel$ME >= 0))
)

read_signal <- function(file, expected_value_name) {
  signal <- fread(file, na.strings = c("", "NA"), showProgress = FALSE)
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
stopifnot(!anyNA(panel$RF))
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
  anyDuplicated(duration, by = c("PERMNO", "FF.YEAR")) == 0L
)
setnames(duration, "FF.YEAR", "DUR_YEAR")
panel[, DUR_YEAR := YYYYMM %/% 100L - as.integer(YYYYMM %% 100L <= 5L)]
panel[duration, DUR := i.DUR, on = .(PERMNO, DUR_YEAR)]
rm(duration)
invisible(gc())

# -----------------------------------------------------------------------------
# Use June NYSE breakpoints to assign annual BM, GP, and DUR deciles.
# -----------------------------------------------------------------------------

june_master <- panel[
  YYYYMM %% 100L == 6L & YYYYMM %/% 100L >= 1973L &
    YYYYMM %/% 100L <= 2024L,
  .(
    PERMNO,
    SORT_YEAR = YYYYMM %/% 100L,
    EXCHCD,
    BM_CZ,
    GP_CZ,
    DUR
  )
]
stopifnot(anyDuplicated(june_master, by = c("PERMNO", "SORT_YEAR")) == 0L)

assign_nyse_deciles <- function(data, signal_column, decile_column) {
  finite_data <- data[is.finite(get(signal_column))]
  breakpoints <- finite_data[
    EXCHCD == 1L,
    as.list(setNames(
      quantile(
        get(signal_column),
        probs = breakpoint_probabilities,
        type = 7,
        names = FALSE
      ),
      breakpoint_names
    )),
    by = SORT_YEAR
  ]
  stopifnot(
    uniqueN(breakpoints$SORT_YEAR) == 52L,
    !breakpoints[, anyNA(.SD), .SDcols = breakpoint_names]
  )
  assigned <- merge(
    finite_data[, .(PERMNO, SORT_YEAR, SIGNAL_VALUE = get(signal_column))],
    breakpoints,
    by = "SORT_YEAR",
    all.x = TRUE,
    sort = FALSE
  )
  assigned[, (decile_column) := 1L]
  for (breakpoint_name in breakpoint_names) {
    assigned[
      SIGNAL_VALUE >= get(breakpoint_name),
      (decile_column) := get(decile_column) + 1L
    ]
  }
  stopifnot(all(assigned[[decile_column]] %in% 1:10))
  assigned[, c("SIGNAL_VALUE", breakpoint_names) := NULL]
  assigned
}

annual_assignments <- unique(june_master[, .(PERMNO, SORT_YEAR)])
for (signal_specification in list(
  c("BM_CZ", "D_BM"),
  c("GP_CZ", "D_GP"),
  c("DUR", "D_DUR")
)) {
  assignment <- assign_nyse_deciles(
    june_master,
    signal_specification[1L],
    signal_specification[2L]
  )
  annual_assignments <- merge(
    annual_assignments,
    assignment,
    by = c("PERMNO", "SORT_YEAR"),
    all.x = TRUE,
    sort = FALSE
  )
}
stopifnot(anyDuplicated(
  annual_assignments,
  by = c("PERMNO", "SORT_YEAR")
) == 0L)
rm(june_master, assignment)
invisible(gc())

# -----------------------------------------------------------------------------
# Match annual assignments and month-t ME to exact month-t+1 excess returns.
# -----------------------------------------------------------------------------

formation_sample <- panel[
  YYYYMM >= 197306L & YYYYMM <= 202411L,
  .(
    PERMNO,
    FORMATION_YYYYMM = YYYYMM,
    FORMATION_INDEX = MONTH_INDEX,
    SORT_YEAR = YYYYMM %/% 100L - as.integer(YYYYMM %% 100L <= 5L),
    ME
  )
]
formation_sample <- merge(
  formation_sample,
  annual_assignments,
  by = c("PERMNO", "SORT_YEAR"),
  all.x = TRUE,
  sort = FALSE
)

next_returns <- panel[
  YYYYMM >= 197307L & YYYYMM <= 202412L &
    is.finite(RET_ADJ) & is.finite(RF),
  .(
    PERMNO,
    FORMATION_INDEX = MONTH_INDEX - 1L,
    RETURN_YYYYMM = YYYYMM,
    XRET_ADJ = RET_ADJ - RF
  )
]
realized_sample <- merge(
  formation_sample,
  next_returns,
  by = c("PERMNO", "FORMATION_INDEX"),
  all = FALSE,
  sort = FALSE
)
stopifnot(
  all(realized_sample$RETURN_YYYYMM ==
    next_yyyymm(realized_sample$FORMATION_YYYYMM)),
  uniqueN(realized_sample$RETURN_YYYYMM) == 618L,
  min(realized_sample$RETURN_YYYYMM) == 197307L,
  max(realized_sample$RETURN_YYYYMM) == 202412L,
  all(diff(sort(unique(month_number(realized_sample$RETURN_YYYYMM)))) == 1L)
)
rm(formation_sample, next_returns, panel, annual_assignments)
invisible(gc())

# -----------------------------------------------------------------------------
# Construct annual NYSE-breakpoint portfolios and their average signal deciles.
# -----------------------------------------------------------------------------

sort_definitions <- list(BM = "D_BM", GP = "D_GP", DUR = "D_DUR")
portfolio_list <- list()
portfolio_index <- 0L

for (weighting in c("VW", "EW")) {
  for (sort_signal in names(sort_definitions)) {
    sort_column <- sort_definitions[[sort_signal]]
    portfolio_sample <- realized_sample[
      !is.na(get(sort_column)) & is.finite(XRET_ADJ)
    ]
    if (weighting == "VW") {
      portfolio_sample <- portfolio_sample[is.finite(ME) & ME > 0]
    }
    portfolio_sample[, PORTFOLIO_DECILE := get(sort_column)]

    portfolio_index <- portfolio_index + 1L
    portfolio_list[[portfolio_index]] <- portfolio_sample[
      ,
      {
        if (weighting == "VW") {
          weights <- ME / sum(ME)
          stopifnot(abs(sum(weights) - 1) < 1e-10)
          portfolio_return <- sum(weights * XRET_ADJ)
          weight_sum <- sum(weights)
        } else {
          portfolio_return <- mean(XRET_ADJ)
          weight_sum <- NA_real_
        }
        list(
          XRET = portfolio_return,
          DEC_BM = mean(D_BM, na.rm = TRUE),
          DEC_GP = mean(D_GP, na.rm = TRUE),
          DEC_DUR = mean(D_DUR, na.rm = TRUE),
          N_STOCKS = .N,
          N_DEC_BM = sum(!is.na(D_BM)),
          N_DEC_GP = sum(!is.na(D_GP)),
          N_DEC_DUR = sum(!is.na(D_DUR)),
          WEIGHT_SUM = weight_sum
        )
      },
      by = .(RETURN_YYYYMM, PORTFOLIO_DECILE)
    ][
      ,
      `:=`(
        WEIGHTING = weighting,
        SORT_SIGNAL = sort_signal,
        PORTFOLIO_ID = paste(sort_signal, PORTFOLIO_DECILE, sep = "_")
      )
    ]
  }
}

portfolio_panel <- rbindlist(portfolio_list, use.names = TRUE)
setorder(portfolio_panel, WEIGHTING, SORT_SIGNAL, RETURN_YYYYMM, PORTFOLIO_DECILE)
stopifnot(
  all(is.finite(portfolio_panel$XRET)),
  all(is.finite(portfolio_panel$DEC_BM)),
  all(is.finite(portfolio_panel$DEC_GP)),
  all(is.finite(portfolio_panel$DEC_DUR)),
  portfolio_panel[WEIGHTING == "VW", all(abs(WEIGHT_SUM - 1) < 1e-10)],
  portfolio_panel[WEIGHTING == "EW", all(is.na(WEIGHT_SUM))]
)
rm(portfolio_list, realized_sample)
invisible(gc())

# -----------------------------------------------------------------------------
# Estimate seven pooled portfolio regressions with Driscoll-Kraay covariance.
# -----------------------------------------------------------------------------

model_specifications <- list(
  i = list(sorts = "BM", regressors = "DEC_BM"),
  ii = list(sorts = "GP", regressors = "DEC_GP"),
  iii = list(sorts = "DUR", regressors = "DEC_DUR"),
  iv = list(sorts = c("BM", "GP"), regressors = c("DEC_BM", "DEC_GP")),
  v = list(sorts = c("BM", "DUR"), regressors = c("DEC_DUR", "DEC_BM")),
  vi = list(sorts = c("DUR", "GP"), regressors = c("DEC_DUR", "DEC_GP")),
  vii = list(
    sorts = c("BM", "GP", "DUR"),
    regressors = c("DEC_DUR", "DEC_BM", "DEC_GP")
  )
)
coefficient_map <- c(
  `(Intercept)` = "INTERCEPT",
  DEC_BM = "B_BM",
  DEC_GP = "B_GP",
  DEC_DUR = "B_DUR"
)

regression_rows <- list()
regression_index <- 0L

for (weighting in c("VW", "EW")) {
  for (specification in names(model_specifications)) {
    specification_definition <- model_specifications[[specification]]
    regression_data <- portfolio_panel[
      WEIGHTING == weighting &
        SORT_SIGNAL %chin% specification_definition$sorts
    ]
    required_columns <- c("XRET", specification_definition$regressors)
    regression_data <- regression_data[
      complete.cases(regression_data[, ..required_columns]) &
        rowSums(!is.finite(as.matrix(
          regression_data[, ..required_columns]
        ))) == 0L
    ]
    setorder(regression_data, PORTFOLIO_ID, RETURN_YYYYMM)

    stopifnot(
      uniqueN(regression_data$RETURN_YYYYMM) == 618L,
      min(regression_data$RETURN_YYYYMM) == 197307L,
      max(regression_data$RETURN_YYYYMM) == 202412L,
      nrow(regression_data) ==
        618L * 10L * length(specification_definition$sorts)
    )

    formula <- reformulate(
      specification_definition$regressors,
      response = "XRET"
    )
    panel_data <- pdata.frame(
      regression_data,
      index = c("PORTFOLIO_ID", "RETURN_YYYYMM"),
      drop.index = FALSE,
      row.names = FALSE
    )
    pooled_model <- plm(
      formula,
      data = panel_data,
      model = "pooling"
    )
    dk_lag <- floor(uniqueN(regression_data$RETURN_YYYYMM)^(1 / 4))
    dk_covariance <- vcovSCC(
      pooled_model,
      type = "HC0",
      maxlag = dk_lag,
      inner = "cluster",
      wj = function(j, maxlag) 1 - j / (maxlag + 1)
    )
    standard_errors <- sqrt(diag(dk_covariance))
    estimates <- coef(pooled_model)
    t_statistics <- estimates / standard_errors
    p_values <- 2 * pnorm(-abs(t_statistics))

    for (coefficient_name in names(estimates)) {
      regression_index <- regression_index + 1L
      regression_rows[[regression_index]] <- data.table(
        WEIGHTING = weighting,
        SPECIFICATION = specification,
        COEFFICIENT = unname(coefficient_map[coefficient_name]),
        ESTIMATE = unname(estimates[coefficient_name]),
        DRISCOLL_KRAAY_SE = unname(standard_errors[coefficient_name]),
        T_STATISTIC = unname(t_statistics[coefficient_name]),
        P_VALUE = unname(p_values[coefficient_name]),
        SIGNIFICANCE = fifelse(
          p_values[coefficient_name] < 0.01, "***",
          fifelse(
            p_values[coefficient_name] < 0.05, "**",
            fifelse(p_values[coefficient_name] < 0.10, "*", "")
          )
        ),
        R_SQUARED = unname(summary(pooled_model)$r.squared["rsq"]),
        N_OBS = nobs(pooled_model),
        N_MONTHS = uniqueN(regression_data$RETURN_YYYYMM),
        N_PORTFOLIOS = uniqueN(regression_data$PORTFOLIO_ID),
        FIRST_RETURN_YYYYMM = min(regression_data$RETURN_YYYYMM),
        LAST_RETURN_YYYYMM = max(regression_data$RETURN_YYYYMM),
        DK_KERNEL = "Bartlett",
        DK_LAG_RULE = "floor(T^(1/4))",
        DK_LAG = dk_lag,
        DK_TYPE = "HC0",
        DK_INNER = "cluster",
        DK_ADJUST = FALSE
      )
    }
  }
}

regression_results <- rbindlist(regression_rows)
setorder(regression_results, WEIGHTING, SPECIFICATION, COEFFICIENT)
stopifnot(
  all(is.finite(regression_results$ESTIMATE)),
  all(is.finite(regression_results$DRISCOLL_KRAAY_SE)),
  all(regression_results$DRISCOLL_KRAAY_SE > 0),
  all(is.finite(regression_results$T_STATISTIC)),
  all(regression_results$N_MONTHS == 618L),
  all(regression_results$FIRST_RETURN_YYYYMM == 197307L),
  all(regression_results$LAST_RETURN_YYYYMM == 202412L),
  all(regression_results$DK_LAG == 4L),
  all(regression_results$DK_TYPE == "HC0"),
  all(regression_results$DK_INNER == "cluster"),
  !any(regression_results$DK_ADJUST)
)
fwrite(regression_results, "code/3e_regressions.csv")

# -----------------------------------------------------------------------------
# Write the requested two-panel LaTeX table.
# -----------------------------------------------------------------------------

coefficient_labels <- c(
  INTERCEPT = "Intercept",
  B_BM = "$b_{BM}$",
  B_GP = "$b_{GP}$",
  B_DUR = "$b_{Dur}$"
)

format_estimate <- function(row) {
  if (nrow(row) == 0L) return("")
  if (nzchar(row$SIGNIFICANCE)) {
    sprintf("$%.4f^{%s}$", row$ESTIMATE, row$SIGNIFICANCE)
  } else {
    sprintf("$%.4f$", row$ESTIMATE)
  }
}

format_t_statistic <- function(row) {
  if (nrow(row) == 0L) return("")
  sprintf("$(%.2f)$", row$T_STATISTIC)
}

latex_lines <- c(
  "\\begin{table}[H]",
  "  \\centering",
  "  \\caption{Pooled regressions of portfolio excess returns}",
  "  \\label{tab:3e}",
  "  \\resizebox{\\textwidth}{!}{%",
  "  \\begin{tabular}{lrrrrrrr}",
  "    \\toprule",
  "    & (i) & (ii) & (iii) & (iv) & (v) & (vi) & (vii) \\\\",
  "    \\midrule"
)

for (weighting in c("VW", "EW")) {
  latex_lines <- c(
    latex_lines,
    sprintf(
      "    \\multicolumn{8}{l}{\\textit{Panel %s: %s portfolios}} \\\\",
      ifelse(weighting == "VW", "A", "B"),
      ifelse(weighting == "VW", "Value-weighted", "Equal-weighted")
    )
  )

  for (coefficient_name in names(coefficient_labels)) {
    estimates <- character(length(model_specifications))
    t_statistics <- character(length(model_specifications))
    for (spec_index in seq_along(model_specifications)) {
      specification <- names(model_specifications)[spec_index]
      row <- regression_results[
        WEIGHTING == weighting &
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
      sprintf("    & %s \\\\", paste(t_statistics, collapse = " & "))
    )
  }

  model_statistics <- unique(regression_results[
    WEIGHTING == weighting,
    .(SPECIFICATION, R_SQUARED, N_OBS)
  ])
  r_squared <- vapply(
    names(model_specifications),
    function(specification) sprintf(
      "%.3f",
      model_statistics[SPECIFICATION == specification, R_SQUARED]
    ),
    character(1L)
  )
  observations <- vapply(
    names(model_specifications),
    function(specification) sprintf(
      "%d",
      model_statistics[SPECIFICATION == specification, N_OBS]
    ),
    character(1L)
  )
  latex_lines <- c(
    latex_lines,
    sprintf("    $R^2$ & %s \\\\", paste(r_squared, collapse = " & ")),
    sprintf("    Observations & %s \\\\", paste(observations, collapse = " & "))
  )
  if (weighting == "VW") latex_lines <- c(latex_lines, "    \\midrule")
}

latex_lines <- c(
  latex_lines,
  "    \\bottomrule",
  "  \\end{tabular}%",
  "  }",
  "  \\begin{minipage}{\\textwidth}",
  "  \\footnotesize \\textit{Notes:} The sample is July 1973--December 2024. Driscoll--Kraay $t$-statistics are in parentheses and use \\texttt{plm::vcovSCC} with \\texttt{type = HC0}, \\texttt{inner = cluster}, Bartlett weights, four lags from $\\lfloor T^{1/4}\\rfloor$, and no finite-sample adjustment. $^{***}$, $^{**}$, and $^{*}$ denote significance at the 1\\%, 5\\%, and 10\\% levels, respectively.",
  "  \\end{minipage}",
  "\\end{table}",
  ""
)
writeLines(latex_lines, "figures/3e.tex", useBytes = TRUE)

print(regression_results)
