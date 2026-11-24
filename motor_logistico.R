# Motor externo de regresión logística para Player One
# Recibe tablas ya preparadas por Nushell y solo ajusta glm() y emite log-odds (eta).

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) {
  stop("Uso: Rscript motor_logistico.R <train.csv> <test.csv> <out_coef.csv> <out_pred.csv>")
}

train_path <- args[1]
test_path  <- args[2]
coef_path  <- args[3]
pred_path  <- args[4]

train_df <- read.csv(train_path)
test_df  <- read.csv(test_path)

modelo <- glm(sube ~ sin_h + cos_h + variacion_prev + gratis,
              data = train_df,
              family = binomial(link = "logit"))

# Guardar coeficientes y estadísticos del ajuste
s <- summary(modelo)$coefficients
coef_df <- data.frame(
  termino  = rownames(s),
  estimado = s[, 1],
  error_std = s[, 2],
  z_valor  = s[, 3],
  p_valor  = s[, 4],
  row.names = NULL
)
write.csv(coef_df, coef_path, row.names = FALSE)

# Emitir predictor lineal (log-odds); Nushell convierte a probabilidades
eta_test <- as.numeric(predict(modelo, newdata = test_df, type = "link"))
write.csv(data.frame(eta = eta_test), pred_path, row.names = FALSE)
