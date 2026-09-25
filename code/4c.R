rm(list = ls())
library(tidyverse)
library(sandwich)

# Load and reshape the five requested Fama-Bliss maturities as in Question 4a.
bonds <- read.csv("Bond Dataset.csv")
required_columns <- c("KYTREASNOX", "TTERMLBL", "MCALDT", "TMYTM")

stopifnot(all(required_columns %in% names(bonds)))

selected_ids <- 2000047:2000051
selected_bonds <- bonds |>
  filter(KYTREASNOX %in% selected_ids) |>
  mutate(
    date = as.Date(MCALDT),
    month = as.Date(format(date, "%Y-%m-01")),
    maturity = KYTREASNOX - 2000046L,
    Y = TMYTM / 100
  )

bond_combinations <- selected_bonds |>
  distinct(KYTREASNOX, TTERMLBL) |>
  arrange(KYTREASNOX)

expected_labels <- sprintf(
  "Fama Bliss Discount Bonds - %d-Year (Nominal)",
  1:5
)

stopifnot(
  nrow(bond_combinations) == 5L,
  identical(bond_combinations$KYTREASNOX, selected_ids),
  identical(bond_combinations$TTERMLBL, expected_labels),
  all(!is.na(selected_bonds$date)),
  all(is.finite(selected_bonds$Y)),
  all(selected_bonds$Y > -1)
)

month_maturity_counts <- selected_bonds |>
  count(month, maturity, name = "observations")

stopifnot(
  all(month_maturity_counts$observations == 1L),
  n_distinct(selected_bonds$month) == 871L,
  nrow(month_maturity_counts) == 871L * 5L
)

monthly_yields <- selected_bonds |>
  select(month, maturity, Y) |>
  pivot_wider(
    names_from = maturity,
    values_from = Y,
    names_prefix = "Y_"
  ) |>
  arrange(month)

yield_columns <- paste0("Y_", 1:5)
stopifnot(
  nrow(monthly_yields) == 871L,
  all(yield_columns %in% names(monthly_yields)),
  all(rowSums(is.na(monthly_yields[, yield_columns])) == 0L),
  monthly_yields$month[1] == as.Date("1952-06-01"),
  monthly_yields$month[nrow(monthly_yields)] == as.Date("2024-12-01")
)

month_index <- 12L * as.integer(format(monthly_yields$month, "%Y")) +
  as.integer(format(monthly_yields$month, "%m"))
stopifnot(all(diff(month_index) == 1L))

# Reconstruct the Question 4a log yields, forward rates, and annual returns.
Y <- as.matrix(monthly_yields[, yield_columns])
colnames(Y) <- paste0("H", 1:5)
log_yield <- log1p(Y)

forward_rate <- matrix(
  NA_real_,
  nrow = nrow(log_yield),
  ncol = ncol(log_yield),
  dimnames = dimnames(log_yield)
)
annual_return <- forward_rate

forward_rate[, 1] <- log_yield[, 1]
annual_return[, 1] <- dplyr::lag(log_yield[, 1], n = 12L)

for (H in 2:5) {
  forward_rate[, H] <-
    H * log_yield[, H] - (H - 1L) * log_yield[, H - 1L]
  annual_return[, H] <-
    H * dplyr::lag(log_yield[, H], n = 12L) -
    (H - 1L) * log_yield[, H - 1L]
}

xy <- sweep(
  log_yield[, 2:5, drop = FALSE],
  1,
  log_yield[, 1],
  "-"
)
xf <- sweep(
  forward_rate[, 2:5, drop = FALSE],
  1,
  forward_rate[, 1],
  "-"
)
xr <- sweep(
  annual_return[, 2:5, drop = FALSE],
  1,
  annual_return[, 1],
  "-"
)

stopifnot(
  all(is.finite(xy)),
  all(is.finite(xf)),
  all(is.na(xr[1:12, ])),
  all(is.finite(xr[13:nrow(xr), ])),
  max(abs(xf[, 1] - 2 * xy[, 1])) < 1e-14
)

# The updated prompt specifies the same 811 forecast-origin months as 4b.
common_sample <- which(
  monthly_yields$month >= as.Date("1952-06-01") &
    monthly_yields$month <= as.Date("2019-12-01")
)
outcome_sample <- common_sample + 12L

stopifnot(
  identical(common_sample, seq_len(811L)),
  length(outcome_sample) == 811L,
  monthly_yields$month[common_sample[1]] == as.Date("1952-06-01"),
  monthly_yields$month[common_sample[length(common_sample)]] ==
    as.Date("2019-12-01"),
  monthly_yields$month[outcome_sample[1]] == as.Date("1953-06-01"),
  monthly_yields$month[outcome_sample[length(outcome_sample)]] ==
    as.Date("2020-12-01"),
  all(is.finite(xf[common_sample, ])),
  all(is.finite(xr[outcome_sample, ]))
)

# Newey-West covariance using the assignment's exact normalization:
# Bartlett weights, Omega_l divided by T-l, and no finite-sample correction.
newey_west_covariance <- function(model, lag) {
  X <- model.matrix(model)
  score <- X * residuals(model)
  T_reg <- nrow(X)

  stopifnot(
    length(lag) == 1L,
    is.finite(lag),
    lag == as.integer(lag),
    lag >= 0L,
    lag < T_reg,
    qr(X)$rank == ncol(X)
  )
  lag <- as.integer(lag)

  Q_inv <- solve(crossprod(X) / T_reg)
  S_HAC <- crossprod(score) / T_reg

  if (lag > 0L) {
    for (ell in seq_len(lag)) {
      current_score <- score[(ell + 1L):T_reg, , drop = FALSE]
      lagged_score <- score[seq_len(T_reg - ell), , drop = FALSE]
      Omega_ell <- crossprod(current_score, lagged_score) / (T_reg - ell)
      weight <- 1 - ell / (lag + 1L)
      S_HAC <- S_HAC + weight * (Omega_ell + t(Omega_ell))
    }
  }

  covariance <- Q_inv %*% S_HAC %*% Q_inv / T_reg
  covariance <- (covariance + t(covariance)) / 2
  dimnames(covariance) <- list(colnames(X), colnames(X))
  covariance
}

results <- vector("list", 4L)

for (H in 2:5) {
  maturity_column <- H - 1L
  regression_data <- tibble(
    xr_t_plus_1 = xr[outcome_sample, maturity_column],
    xf_t = xf[common_sample, maturity_column]
  )

  stopifnot(
    nrow(regression_data) == 811L,
    all(is.finite(unlist(regression_data))),
    var(regression_data$xf_t) > 0
  )

  model <- lm(xr_t_plus_1 ~ xf_t, data = regression_data)
  automatic_bandwidth <- sandwich::bwNeweyWest(
    model,
    kernel = "Bartlett",
    prewhite = FALSE
  )
  automatic_lag <- as.integer(floor(automatic_bandwidth))
  nw_covariance <- newey_west_covariance(model, lag = automatic_lag)

  slope_name <- "xf_t"
  slope <- unname(coef(model)[[slope_name]])
  standard_error <- sqrt(nw_covariance[slope_name, slope_name])
  t_statistic <- slope / standard_error

  stopifnot(
    nobs(model) == 811L,
    is.finite(automatic_bandwidth),
    automatic_bandwidth >= 0,
    automatic_lag < nobs(model),
    is.finite(standard_error),
    standard_error > 0,
    is.finite(t_statistic)
  )

  results[[H - 1L]] <- tibble(
    H = H,
    observations = nobs(model),
    automatic_bandwidth = automatic_bandwidth,
    nw_lag = automatic_lag,
    b_hat = slope,
    nw_standard_error = standard_error,
    t_stat = t_statistic,
    r_squared = summary(model)$r.squared
  )
}

regression_results <- bind_rows(results)

expected_bandwidths <- c(
  20.651857223997975,
  20.636336717249925,
  20.961358558999230,
  19.931120114442894
)
expected_results <- matrix(
  c(
    0.693141944383449, 0.227084437188868, 3.05235335791399,
    0.0808508913095210,
    0.902802418022931, 0.294369971560091, 3.06689712010465,
    0.0889158189363175,
    1.14763242456429, 0.331685002594795, 3.46000698128127,
    0.114811650018672,
    0.971477409458638, 0.354300914743569, 2.74195569086171,
    0.0685356177202551
  ),
  nrow = 4L,
  byrow = TRUE
)

stopifnot(
  identical(regression_results$observations, rep(811L, 4L)),
  identical(regression_results$nw_lag, c(20L, 20L, 20L, 19L)),
  max(abs(
    regression_results$automatic_bandwidth - expected_bandwidths
  )) < 1e-10,
  max(abs(
    as.matrix(regression_results[, c(
      "b_hat",
      "nw_standard_error",
      "t_stat",
      "r_squared"
    )]) - expected_results
  )) < 1e-11
)

# Verify the H=2 identity requested in the prompt against Question 4b.
q4b_h2_data <- tibble(
  average_hold_to_maturity_xr = xr[outcome_sample, 1] / 2,
  xy_t = xy[common_sample, 1]
)
q4b_h2_model <- lm(
  average_hold_to_maturity_xr ~ xy_t,
  data = q4b_h2_data
)
q4b_h2_slope <- unname(coef(q4b_h2_model)[["xy_t"]])

stopifnot(
  abs(regression_results$b_hat[regression_results$H == 2L] -
    q4b_h2_slope) < 1e-12,
  abs(q4b_h2_slope - 0.693141944383449) < 1e-12
)

# Format the requested LaTeX table to exactly four decimal places.
latex_rows <- sprintf(
  "    %d & %.4f & %.4f & %.4f \\\\",
  regression_results$H,
  regression_results$b_hat,
  regression_results$t_stat,
  regression_results$r_squared
)

latex_table <- c(
  "\\begin{table}[htbp]",
  "  \\centering",
  "  \\caption{Predictive regressions of excess bond returns on excess forward rates}",
  "  \\label{tab:q4c}",
  "  \\begin{tabular}{crrr}",
  "    \\toprule",
  "    $H$ & $\\hat{b}^{(H)}$ & Newey--West $t$-stat & $R^2$ \\\\",
  "    \\midrule",
  latex_rows,
  "    \\bottomrule",
  "  \\end{tabular}",
  "\\end{table}"
)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
writeLines(latex_table, "figures/4c.tex")

print(
  regression_results |>
    mutate(across(
      c(
        automatic_bandwidth,
        b_hat,
        nw_standard_error,
        t_stat,
        r_squared
      ),
      ~ sprintf("%.6f", .x)
    ))
)
cat(sprintf(
  "Question 4b/4c H=2 slope difference: %.3e\n",
  regression_results$b_hat[regression_results$H == 2L] - q4b_h2_slope
))
