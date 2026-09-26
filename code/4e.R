rm(list = ls())
library(tidyverse)
library(sandwich)

# Reconstruct the Question 4a annual excess bond returns.
bonds <- read.csv("Bond Dataset.csv")
required_bond_columns <- c("KYTREASNOX", "TTERMLBL", "MCALDT", "TMYTM")

stopifnot(all(required_bond_columns %in% names(bonds)))

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

bond_month_index <- 12L * as.integer(format(monthly_yields$month, "%Y")) +
  as.integer(format(monthly_yields$month, "%m"))
stopifnot(all(diff(bond_month_index) == 1L))

Y <- as.matrix(monthly_yields[, yield_columns])
colnames(Y) <- paste0("H", 1:5)
log_yield <- log1p(Y)

annual_return <- matrix(
  NA_real_,
  nrow = nrow(log_yield),
  ncol = ncol(log_yield),
  dimnames = dimnames(log_yield)
)

annual_return[, 1] <- dplyr::lag(log_yield[, 1], n = 12L)

for (H in 2:5) {
  annual_return[, H] <-
    H * dplyr::lag(log_yield[, H], n = 12L) -
    (H - 1L) * log_yield[, H - 1L]
}

xr <- sweep(
  annual_return[, 2:5, drop = FALSE],
  1,
  annual_return[, 1],
  "-"
)

stopifnot(
  all(is.na(xr[1:12, ])),
  all(is.finite(xr[13:nrow(xr), ])),
  all(colSums(is.finite(xr)) == 859L)
)

# Use the Question 4d Cochrane-Piazzesi factor at each forecast origin.
factor_raw <- read_csv("code/4d.csv", show_col_types = FALSE)
required_factor_columns <- c("month", "cp_t")
stopifnot(all(required_factor_columns %in% names(factor_raw)))

factor_data <- factor_raw |>
  transmute(
    month = as.Date(month),
    cp_t = as.numeric(cp_t)
  ) |>
  arrange(month)

factor_month_index <- 12L * as.integer(format(factor_data$month, "%Y")) +
  as.integer(format(factor_data$month, "%m"))

stopifnot(
  nrow(factor_data) == 859L,
  n_distinct(factor_data$month) == 859L,
  all(!is.na(factor_data$month)),
  all(is.finite(factor_data$cp_t)),
  all(diff(factor_month_index) == 1L),
  factor_data$month[1] == as.Date("1952-06-01"),
  factor_data$month[nrow(factor_data)] == as.Date("2023-12-01"),
  abs(factor_data$cp_t[1] - 0.0021164402477646172) < 1e-12,
  abs(factor_data$cp_t[nrow(factor_data)] -
    (-0.0028518547661805292)) < 1e-12,
  abs(mean(factor_data$cp_t) - 0.019983169671138477) < 1e-12
)

regression_sample <- match(factor_data$month, monthly_yields$month)
outcome_sample <- regression_sample + 12L

stopifnot(
  !anyNA(regression_sample),
  identical(regression_sample, seq_len(859L)),
  length(outcome_sample) == 859L,
  all(outcome_sample <= nrow(monthly_yields)),
  all(bond_month_index[outcome_sample] -
    bond_month_index[regression_sample] == 12L),
  monthly_yields$month[regression_sample[1]] == as.Date("1952-06-01"),
  monthly_yields$month[regression_sample[length(regression_sample)]] ==
    as.Date("2023-12-01"),
  monthly_yields$month[outcome_sample[1]] == as.Date("1953-06-01"),
  monthly_yields$month[outcome_sample[length(outcome_sample)]] ==
    as.Date("2024-12-01"),
  all(is.finite(xr[outcome_sample, ]))
)

# Footnote 3 HAC covariance: Bartlett weights, Omega_l divided by T-l,
# no prewhitening, and no finite-sample correction.
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
    cp_t = factor_data$cp_t
  )

  stopifnot(
    nrow(regression_data) == 859L,
    all(is.finite(unlist(regression_data))),
    var(regression_data$cp_t) > 0
  )

  model <- lm(xr_t_plus_1 ~ cp_t, data = regression_data)
  automatic_bandwidth <- sandwich::bwNeweyWest(
    model,
    kernel = "Bartlett",
    prewhite = FALSE
  )
  automatic_lag <- as.integer(floor(automatic_bandwidth))
  nw_covariance <- newey_west_covariance(model, lag = automatic_lag)

  slope_name <- "cp_t"
  intercept <- unname(coef(model)[["(Intercept)"]])
  slope <- unname(coef(model)[[slope_name]])
  standard_error <- sqrt(nw_covariance[slope_name, slope_name])
  t_statistic <- slope / standard_error

  stopifnot(
    nobs(model) == 859L,
    qr(model.matrix(model))$rank == 2L,
    is.finite(automatic_bandwidth),
    automatic_bandwidth >= 0,
    automatic_lag < nobs(model),
    is.finite(standard_error),
    standard_error > 0,
    is.finite(t_statistic),
    abs(t_statistic - slope / standard_error) < 1e-14
  )

  results[[H - 1L]] <- tibble(
    H = H,
    observations = nobs(model),
    automatic_bandwidth = automatic_bandwidth,
    nw_lag = automatic_lag,
    a_hat = intercept,
    b_hat = slope,
    nw_standard_error = standard_error,
    t_stat = t_statistic,
    r_squared = summary(model)$r.squared
  )
}

regression_results <- bind_rows(results)

expected_bandwidths <- c(
  21.606300821708682,
  21.442274772427361,
  21.361424421906584,
  21.161859519096350
)

expected_results <- matrix(
  c(
    0.44176281449767585, 0.10707663931407774,
    4.1256694020989482, 0.13670348175026190,
    0.82744325649158135, 0.20062492349046540,
    4.1243293310509603, 0.14377351525105467,
    1.25171491986210690, 0.28515721702709168,
    4.3895607234208152, 0.17046792155454502,
    1.47907900914862100, 0.35228304940989585,
    4.1985528728282686, 0.15522782961449130
  ),
  nrow = 4L,
  byrow = TRUE
)

stopifnot(
  identical(regression_results$H, 2:5),
  identical(regression_results$observations, rep(859L, 4L)),
  identical(regression_results$nw_lag, rep(21L, 4L)),
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
  )) < 1e-11,
  abs(mean(regression_results$b_hat) - 1) < 1e-12,
  abs(mean(regression_results$a_hat) -
    (-0.013448092468243085)) < 1e-12
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
  "  \\caption{Predictive regressions of excess bond returns on the Cochrane--Piazzesi factor}",
  "  \\label{tab:q4e}",
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
writeLines(latex_table, "figures/4e.tex")

print(
  regression_results |>
    mutate(across(
      c(
        automatic_bandwidth,
        a_hat,
        b_hat,
        nw_standard_error,
        t_stat,
        r_squared
      ),
      ~ sprintf("%.6f", .x)
    ))
)
