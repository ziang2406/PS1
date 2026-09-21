rm(list = ls())
library(tidyverse)

# Load the bond panel and retain the five requested Fama-Bliss maturities.
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

stopifnot(
  nrow(bond_combinations) == 5L,
  identical(bond_combinations$KYTREASNOX, selected_ids),
  identical(sort(unique(selected_bonds$maturity)), 1:5),
  all(!is.na(selected_bonds$date)),
  all(is.finite(selected_bonds$TMYTM)),
  all(is.finite(selected_bonds$Y)),
  all(selected_bonds$Y > -1)
)

expected_labels <- sprintf(
  "Fama Bliss Discount Bonds - %d-Year (Nominal)",
  1:5
)
stopifnot(identical(bond_combinations$TTERMLBL, expected_labels))

# Verify one yield per month-maturity cell before reshaping.
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

# Construct log yields, forward rates, and annual returns.
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

# The user-specified H = 1 definitions.
forward_rate[, 1] <- log_yield[, 1]
annual_return[, 1] <- dplyr::lag(log_yield[, 1], n = 12L)

for (H in 2:5) {
  forward_rate[, H] <-
    H * log_yield[, H] - (H - 1L) * log_yield[, H - 1L]
  annual_return[, H] <-
    H * dplyr::lag(log_yield[, H], n = 12L) -
    (H - 1L) * log_yield[, H - 1L]
}

# Calculate maturity-H values in excess of their one-year counterparts.
xy <- sweep(log_yield[, 2:5, drop = FALSE], 1, log_yield[, 1], "-")
xf <- sweep(forward_rate[, 2:5, drop = FALSE], 1, forward_rate[, 1], "-")
xr <- sweep(annual_return[, 2:5, drop = FALSE], 1, annual_return[, 1], "-")

stopifnot(
  all(is.finite(xy)),
  all(is.finite(xf)),
  all(is.na(xr[1:12, ])),
  all(is.finite(xr[13:nrow(xr), ])),
  all(colSums(is.finite(xy)) == 871L),
  all(colSums(is.finite(xf)) == 871L),
  all(colSums(is.finite(xr)) == 859L)
)

average_results <- tibble(
  H = 2:5,
  average_xy = colMeans(xy),
  average_xf = colMeans(xf),
  average_xr = colMeans(xr, na.rm = TRUE)
)

expected_results <- matrix(
  c(
    0.00168612801160870, 0.00337225602321741, 0.00315423321411730,
    0.00327787166226342, 0.00646135896357286, 0.00606929029638862,
    0.00465957935461157, 0.00880470243165600, 0.00819824552895281,
    0.00563910893279226, 0.00955722724551506, 0.00871853977212253
  ),
  nrow = 4L,
  byrow = TRUE
)

stopifnot(
  max(abs(
    as.matrix(average_results[, c("average_xy", "average_xf", "average_xr")]) -
      expected_results
  )) < 1e-12
)

# Format the requested LaTeX table to exactly six decimal places.
latex_rows <- sprintf(
  "    %d & %.6f & %.6f & %.6f \\\\",
  average_results$H,
  average_results$average_xy,
  average_results$average_xf,
  average_results$average_xr
)

latex_table <- c(
  "\\begin{table}[htbp]",
  "  \\centering",
  "  \\caption{Average excess bond yields, forward rates, and annual returns}",
  "  \\label{tab:q4a}",
  "  \\begin{tabular}{crrr}",
  "    \\toprule",
  "    $H$ & $\\overline{xy}^{(H)}$ & $\\overline{xf}^{(H)}$ & $\\overline{xr}^{(H)}$ \\\\",
  "    \\midrule",
  latex_rows,
  "    \\bottomrule",
  "  \\end{tabular}",
  "\\end{table}"
)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
writeLines(latex_table, "figures/4a.tex")

print(bond_combinations)
print(
  average_results |>
    mutate(across(starts_with("average_"), ~ sprintf("%.6f", .x)))
)
