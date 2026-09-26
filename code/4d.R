rm(list = ls())
library(tidyverse)

# Load and reshape the five requested Fama-Bliss maturities as in Question 4a.
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

# Reconstruct the Question 4a log forward rates and annual excess returns.
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

xr <- sweep(
  annual_return[, 2:5, drop = FALSE],
  1,
  annual_return[, 1],
  "-"
)

stopifnot(
  all(is.finite(forward_rate)),
  all(is.na(xr[1:12, ])),
  all(is.finite(xr[13:nrow(xr), ]))
)

# Use every t for which the H=5 excess return is observed 12 months later.
candidate_origins <- seq_len(nrow(monthly_yields) - 12L)
regression_sample <- candidate_origins[
  is.finite(xr[candidate_origins + 12L, 4])
]
outcome_sample <- regression_sample + 12L

stopifnot(
  identical(regression_sample, seq_len(859L)),
  length(outcome_sample) == 859L,
  monthly_yields$month[regression_sample[1]] == as.Date("1952-06-01"),
  monthly_yields$month[regression_sample[length(regression_sample)]] ==
    as.Date("2023-12-01"),
  monthly_yields$month[outcome_sample[1]] == as.Date("1953-06-01"),
  monthly_yields$month[outcome_sample[length(outcome_sample)]] ==
    as.Date("2024-12-01"),
  all(is.finite(forward_rate[regression_sample, ])),
  all(is.finite(xr[outcome_sample, ]))
)

# Estimate the Cochrane-Piazzesi return-forecasting regression.
regression_data <- tibble(
  average_future_excess_return = rowMeans(xr[outcome_sample, ]),
  f_1 = forward_rate[regression_sample, 1],
  f_2 = forward_rate[regression_sample, 2],
  f_3 = forward_rate[regression_sample, 3],
  f_4 = forward_rate[regression_sample, 4],
  f_5 = forward_rate[regression_sample, 5]
)

cp_model <- lm(
  average_future_excess_return ~ f_1 + f_2 + f_3 + f_4 + f_5,
  data = regression_data
)

theta_hat <- coef(cp_model)
theta_names <- c("theta_0", paste0("theta_", 1:5))
theta_results <- tibble(
  parameter = theta_names,
  estimate = unname(theta_hat)
)

expected_theta <- c(
  -0.013448092468243085,
  -0.987387337232638385,
  -0.211533936348510254,
  0.809338427445137953,
  1.084351848852683320,
  -0.464739643850675233
)

stopifnot(
  nobs(cp_model) == 859L,
  qr(model.matrix(cp_model))$rank == 6L,
  all(is.finite(theta_hat)),
  max(abs(unname(theta_hat) - expected_theta)) < 1e-12,
  abs(summary(cp_model)$r.squared - 0.15750945779275671) < 1e-12
)

# Estimate one return-forecasting regression for each bond maturity K = 2,...,5.
maturity_regression_data <- regression_data |>
  select(f_1, f_2, f_3, f_4, f_5) |>
  mutate(
    xr_2 = xr[outcome_sample, 1],
    xr_3 = xr[outcome_sample, 2],
    xr_4 = xr[outcome_sample, 3],
    xr_5 = xr[outcome_sample, 4]
  )

forecasted_maturities <- 2:5
maturity_models <- set_names(
  map(
    forecasted_maturities,
    function(K) {
      lm(
        reformulate(
          termlabels = paste0("f_", 1:5),
          response = paste0("xr_", K)
        ),
        data = maturity_regression_data
      )
    }
  ),
  forecasted_maturities
)

expected_maturity_theta <- rbind(
  c(
    -0.0068232195949002854,
    -0.4827396125619232703,
    0.1928537746300231503,
    0.2126531751330366371,
    0.3924690087846884334,
    -0.1769482955748130915
  ),
  c(
    -0.010469679871220876,
    -0.810338082323520781,
    -0.297559287086993474,
    1.175504066405646864,
    0.627926095321693856,
    -0.492601210576397719
  ),
  c(
    -0.015346660963083944,
    -1.190091724934451811,
    -0.353600744301324321,
    0.985563813891420226,
    1.621129505565275908,
    -0.802229340631788967
  ),
  c(
    -0.021152809443767143,
    -1.466379929110652292,
    -0.387829488635747899,
    0.863632654350446227,
    1.695882785739069698,
    -0.387179728619698793
  )
)

estimated_maturity_theta <- do.call(
  rbind,
  map(maturity_models, ~ unname(coef(.x)))
)

expected_maturity_r_squared <- c(
  0.14897395375955141,
  0.14852602911411800,
  0.17201407460619259,
  0.15839264789067642
)

stopifnot(
  identical(dim(estimated_maturity_theta), c(4L, 6L)),
  all(map_int(maturity_models, nobs) == 859L),
  all(map_int(maturity_models, ~ qr(model.matrix(.x))$rank) == 6L),
  max(abs(estimated_maturity_theta - expected_maturity_theta)) < 1e-12,
  max(
    abs(
      map_dbl(maturity_models, ~ summary(.x)$r.squared) -
        expected_maturity_r_squared
    )
  ) < 1e-12,
  max(abs(colMeans(estimated_maturity_theta) - unname(theta_hat))) < 1e-12
)

maturity_coefficient_results <- map2_dfr(
  maturity_models,
  forecasted_maturities,
  function(model, K) {
    tibble(
      forecasted_bond_maturity = K,
      parameter = theta_names,
      forward_rate_maturity = c(NA_integer_, 1:5),
      estimate = unname(coef(model))
    )
  }
)

stopifnot(
  nrow(maturity_coefficient_results) == 24L,
  all(maturity_coefficient_results$forecasted_bond_maturity %in% 2:5),
  sum(is.na(maturity_coefficient_results$forward_rate_maturity)) == 4L,
  all(is.finite(maturity_coefficient_results$estimate))
)

# Per prompt/4d.md, cp_t contains the five slope terms and excludes theta_0.
forward_rate_sample <- forward_rate[regression_sample, , drop = FALSE]
cp_t <- drop(forward_rate_sample %*% unname(theta_hat[-1]))

stopifnot(
  length(cp_t) == 859L,
  all(is.finite(cp_t)),
  max(abs(fitted(cp_model) - (unname(theta_hat[1]) + cp_t))) < 1e-12,
  abs(cp_t[1] - 0.0021164402477646172) < 1e-12,
  abs(cp_t[length(cp_t)] - (-0.0028518547661805292)) < 1e-12,
  abs(min(cp_t) - (-0.026343135971908408)) < 1e-12,
  abs(max(cp_t) - 0.062805016034061995) < 1e-12,
  abs(mean(cp_t) - 0.019983169671138477) < 1e-12
)

# Match the factor to the monthly NBER recession indicator by calendar month.
usrec_raw <- read.csv("USREC.csv")
required_usrec_columns <- c("observation_date", "USREC")
stopifnot(all(required_usrec_columns %in% names(usrec_raw)))

usrec <- usrec_raw |>
  transmute(
    month = as.Date(format(as.Date(observation_date), "%Y-%m-01")),
    USREC = as.integer(USREC)
  ) |>
  arrange(month)

usrec_month_index <- 12L * as.integer(format(usrec$month, "%Y")) +
  as.integer(format(usrec$month, "%m"))

stopifnot(
  nrow(usrec) == 2061L,
  n_distinct(usrec$month) == nrow(usrec),
  all(diff(usrec_month_index) == 1L),
  all(!is.na(usrec$month)),
  all(usrec$USREC %in% c(0L, 1L)),
  usrec$month[1] == as.Date("1854-12-01"),
  usrec$month[nrow(usrec)] == as.Date("2026-08-01")
)

factor_results <- tibble(
  month = monthly_yields$month[regression_sample],
  cp_t = cp_t
) |>
  left_join(usrec, by = "month", relationship = "one-to-one")

stopifnot(
  nrow(factor_results) == 859L,
  n_distinct(factor_results$month) == 859L,
  all(is.finite(factor_results$cp_t)),
  all(factor_results$USREC %in% c(0L, 1L)),
  sum(factor_results$USREC == 1L) == 113L,
  factor_results$month[1] == as.Date("1952-06-01"),
  factor_results$month[nrow(factor_results)] == as.Date("2023-12-01")
)

dir.create("code", showWarnings = FALSE, recursive = TRUE)
write_csv(factor_results, "code/4d.csv")
write_csv(
  maturity_coefficient_results,
  "code/4d_2_coefficients.csv"
)

# Convert consecutive recession months into shaded plotting intervals.
recession_intervals <- factor_results |>
  filter(USREC == 1L) |>
  mutate(
    month_number = 12L * as.integer(format(month, "%Y")) +
      as.integer(format(month, "%m")),
    recession_id = cumsum(c(TRUE, diff(month_number) != 1L))
  ) |>
  group_by(recession_id) |>
  summarise(
    start_month = min(month),
    end_month = max(month),
    .groups = "drop"
  ) |>
  mutate(
    end_exclusive = as.Date(format(end_month + 32, "%Y-%m-01"))
  )

stopifnot(
  nrow(recession_intervals) == 11L,
  recession_intervals$start_month[1] == as.Date("1953-08-01"),
  recession_intervals$end_month[1] == as.Date("1954-05-01"),
  recession_intervals$start_month[nrow(recession_intervals)] ==
    as.Date("2020-03-01"),
  recession_intervals$end_month[nrow(recession_intervals)] ==
    as.Date("2020-04-01")
)

date_breaks <- seq.Date(
  as.Date("1955-01-01"),
  as.Date("2020-01-01"),
  by = "5 years"
)

cp_plot <- ggplot(factor_results, aes(x = month, y = cp_t)) +
  geom_rect(
    data = recession_intervals,
    aes(
      xmin = start_month,
      xmax = end_exclusive,
      ymin = -Inf,
      ymax = Inf
    ),
    inherit.aes = FALSE,
    fill = "gray85"
  ) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(color = "red", linewidth = 0.8) +
  scale_x_date(
    breaks = date_breaks,
    date_labels = "%Y",
    limits = range(factor_results$month)
  ) +
  labs(
    x = "Years",
    y = expression(cp[t]),
    title = "Figure 8: Cochrane-Piazzesi factor and NBER recessions"
  ) +
  theme_classic() +
  theme(
    text = element_text(family = "Times New Roman", size = 14),
    plot.title = element_text(hjust = 0.5)
  )

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
ggsave(
  filename = "figures/4d.png",
  plot = cp_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

# Plot the five slope coefficients by predictor maturity for each return maturity.
coefficient_plot_data <- maturity_coefficient_results |>
  filter(!is.na(forward_rate_maturity)) |>
  mutate(
    forecasted_bond_maturity = factor(
      forecasted_bond_maturity,
      levels = 2:5,
      labels = paste0(2:5, "-year bond")
    )
  )

stopifnot(
  nrow(coefficient_plot_data) == 20L,
  identical(
    sort(unique(coefficient_plot_data$forward_rate_maturity)),
    1:5
  )
)

coefficient_plot <- ggplot(
  coefficient_plot_data,
  aes(
    x = forward_rate_maturity,
    y = estimate,
    color = forecasted_bond_maturity,
    group = forecasted_bond_maturity
  )
) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.2) +
  scale_x_continuous(breaks = 1:5) +
  scale_color_manual(
    values = c("black", "red", "blue", "darkgreen"),
    name = "Forecasted bond maturity"
  ) +
  labs(
    x = "Forward-rate maturity (years)",
    y = expression(hat(theta)[H]),
    title = "Forward-rate coefficients by forecasted bond maturity"
  ) +
  theme_classic() +
  theme(
    text = element_text(family = "Times New Roman", size = 12),
    plot.title = element_text(hjust = 0.5),
    legend.position = c(0.20,0.80)
  )

ggsave(
  filename = "figures/4d_2.png",
  plot = coefficient_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

print(
  theta_results |>
    mutate(estimate = sprintf("%.15f", estimate)),
  n = nrow(theta_results)
)
cat(sprintf("Regression R-squared: %.15f\n", summary(cp_model)$r.squared))
print(maturity_coefficient_results, n = nrow(maturity_coefficient_results))
print(factor_results, n = 6L)
