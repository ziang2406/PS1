rm(list = ls())
library(tidyverse)

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

# Reconstruct the log yields and annual excess returns from Question 4a.
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

xy <- sweep(log_yield, 1, log_yield[, 1], "-")
xr <- sweep(annual_return, 1, annual_return[, 1], "-")

stopifnot(
  all(is.finite(xy)),
  all(is.na(xr[1:12, ])),
  all(is.finite(xr[13:nrow(xr), ])),
  max(abs(xy[, 1])) == 0,
  max(abs(xr[13:nrow(xr), 1])) == 0
)

# Construct H-year hold-to-maturity excess returns. A one-year step is a
# 12-row lead because the source observations are monthly.
hold_to_maturity_xr <- matrix(
  NA_real_,
  nrow = nrow(xr),
  ncol = ncol(xr),
  dimnames = dimnames(xr)
)

for (H in 2:5) {
  return_components <- vapply(
    seq_len(H),
    function(h) {
      dplyr::lead(xr[, H - h + 1L], n = 12L * h)
    },
    numeric(nrow(xr))
  )
  hold_to_maturity_xr[, H] <- rowSums(return_components)
}

stopifnot(
  identical(
    as.integer(colSums(is.finite(hold_to_maturity_xr))[-1]),
    c(847L, 835L, 823L, 811L)
  )
)

# The updated prompt requires one common sample where the five-year return is
# complete. All four regressions therefore use these same 811 start months.
common_sample <- which(is.finite(hold_to_maturity_xr[, 5]))

stopifnot(
  identical(common_sample, seq_len(811L)),
  monthly_yields$month[common_sample[1]] == as.Date("1952-06-01"),
  monthly_yields$month[common_sample[length(common_sample)]] ==
    as.Date("2019-12-01"),
  all(is.finite(hold_to_maturity_xr[common_sample, 2:5])),
  all(is.finite(xy[common_sample, 2:5]))
)

# Hansen-Hodrick covariance using the exact normalizations in the prompt:
# equal weights, Omega_l divided by T-l, and L = 12H-1.
hansen_hodrick_covariance <- function(model, lag) {
  X <- model.matrix(model)
  residual <- residuals(model)
  score <- X * residual
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
      S_HAC <- S_HAC + Omega_ell + t(Omega_ell)
    }
  }

  covariance <- Q_inv %*% S_HAC %*% Q_inv / T_reg
  covariance <- (covariance + t(covariance)) / 2
  dimnames(covariance) <- list(colnames(X), colnames(X))
  covariance
}

results <- vector("list", 4L)

for (H in 2:5) {
  regression_data <- tibble(
    average_hold_to_maturity_xr =
      hold_to_maturity_xr[common_sample, H] / H,
    xy_t = xy[common_sample, H]
  )

  stopifnot(
    nrow(regression_data) == 811L,
    all(is.finite(unlist(regression_data)))
  )

  model <- lm(average_hold_to_maturity_xr ~ xy_t, data = regression_data)
  hh_lag <- 12L * H - 1L
  hh_covariance <- hansen_hodrick_covariance(model, lag = hh_lag)
  slope_name <- "xy_t"
  slope <- unname(coef(model)[[slope_name]])
  standard_error <- sqrt(hh_covariance[slope_name, slope_name])
  t_statistic <- slope / standard_error

  stopifnot(
    nobs(model) == 811L,
    is.finite(standard_error),
    standard_error > 0,
    is.finite(t_statistic)
  )

  results[[H - 1L]] <- tibble(
    H = H,
    observations = nobs(model),
    hh_lag = hh_lag,
    b_hat = slope,
    hh_standard_error = standard_error,
    t_stat = t_statistic,
    r_squared = summary(model)$r.squared
  )
}

regression_results <- bind_rows(results)

expected_results <- matrix(
  c(
    0.693141944383449, 0.201653673307018, 3.43728895693429,
    0.0808508913095210,
    0.520068835602744, 0.173416990128181, 2.99894972931046,
    0.0543333219946253,
    0.393466828390540, 0.172866287254906, 2.27613396827538,
    0.0378905568592992,
    0.313984187998462, 0.151567022590697, 2.07158643504114,
    0.0281261150847574
  ),
  nrow = 4L,
  byrow = TRUE
)

stopifnot(
  identical(regression_results$observations, rep(811L, 4L)),
  identical(regression_results$hh_lag, c(23L, 35L, 47L, 59L)),
  max(abs(
    as.matrix(regression_results[, c(
      "b_hat",
      "hh_standard_error",
      "t_stat",
      "r_squared"
    )]) - expected_results
  )) < 1e-12
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
  "  \\caption{Predictive regressions for hold-to-maturity excess bond returns}",
  "  \\label{tab:q4b}",
  "  \\begin{tabular}{crrr}",
  "    \\toprule",
  "    $H$ & $\\hat{b}^{(H)}$ & Hansen--Hodrick $t$-stat & $R^2$ \\\\",
  "    \\midrule",
  latex_rows,
  "    \\bottomrule",
  "  \\end{tabular}",
  "\\end{table}"
)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
writeLines(latex_table, "figures/4b.tex")

print(
  regression_results |>
    mutate(across(
      c(b_hat, hh_standard_error, t_stat, r_squared),
      ~ sprintf("%.6f", .x)
    ))
)
