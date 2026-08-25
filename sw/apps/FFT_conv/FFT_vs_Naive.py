import numpy as np

#  פרמטרים בסיסיים

IN_DIM = 1024
OUT_DIM = 1024
K = 128   # גודל הבלוק

assert IN_DIM % K == 0 and OUT_DIM % K == 0 # בדיקה לווידוא ש K מתחלק במקשלים ללא שארית

np.random.seed(0) #מוודא שהמספרים הרנדומליים שנבחרו פעם אחת יחזרו בכל הרצה


# בניית מטריצה בלוק-סירקולנטית

def make_block_circulant_weights(W, k):
    out_dim, in_dim = W.shape
    num_row_blocks = out_dim // k
    num_col_blocks = in_dim // k

    W_bc = np.zeros_like(W)
    first_cols = np.zeros((num_row_blocks, num_col_blocks, k))

    for i in range(num_row_blocks):
        for j in range(num_col_blocks):
            block = W[i*k:(i+1)*k, j*k:(j+1)*k] # העתקת הבלוק הרלוונטי
            c_ij = block[:, 0].copy()       # לקיחת העמודה הראשונה בלבד
            first_cols[i, j] = c_ij # מטריצת טנזור

            # בונים בלוק סירקולנטי:
            for col in range(k):
                W_bc[i*k:(i+1)*k, j*k + col] = np.roll(c_ij, col) # נדאג שבכל בלוק יש הזזה של איבר בכל וקטור שהופך את המטריצה למחזורית

    return W_bc, first_cols


#  כפל מטריצות נאיבי

def forward_naive(x, W_bc, bias=None):
    y = W_bc @ x
    return y if bias is None else y + bias


#  שימוש ב FFT

def forward_block_circulant_fft(x, first_cols, k, bias=None):
    num_row_blocks, num_col_blocks, _ = first_cols.shape
    out_dim = num_row_blocks * k

    x_blocks = [x[j*k:(j+1)*k] for j in range(num_col_blocks)] # חילוק הקלט לוקטורים באורך K
    x_fft = [np.fft.fft(xb) for xb in x_blocks] # FFT על הקלט

    y = np.zeros(out_dim, dtype=complex) # וקטור הפתרונות

    for i in range(num_row_blocks): #תת וקטור פתרונות של כל בלוק
        y_block = np.zeros(k, dtype=complex)

        for j in range(num_col_blocks):
            c_ij = first_cols[i, j]
            C_fft = np.fft.fft(c_ij)
            y_block += np.fft.ifft(C_fft * x_fft[j]) # סכימה של הכפלות בלוקי העמודות של כפל נקודתי

        y[i*k:(i+1)*k] = y_block #השמה של הפיתרון במקום המיועד בוקטור הפתרונות

    y = y.real #השמטה של החלק המרוכב בפתרון FFT
    return y if bias is None else y + bias


#  הדגמה מלאה

# קלט רנדומי באורך 1024
x = np.random.randn(IN_DIM)

# מטריצת משקלים מלאה 1024×1024 + bias
W = np.random.randn(OUT_DIM, IN_DIM)
bias = np.random.randn(OUT_DIM)

# יצירת גרסה בלוק-סירקולנטית
W_bc, first_cols = make_block_circulant_weights(W, K)

# FC מלאה (Dense)
y_dense = W @ x + bias

# FC דחוסה נאיבית
y_naive = forward_naive(x, W_bc, bias)

# FC דחוסה באמצעות FFT
y_fft = forward_block_circulant_fft(x, first_cols, K, bias)

#  בדיקות

# לוודא שאכן ההפרש בין הפתרון של הכפלת מטריצות ל FFT קרוב ל-0
fft_error = np.max(np.abs(y_naive - y_fft))
print("FFT accuracy error:", fft_error)

# כמה התרחקנו על ידי דחיסת מטריצת המשקלים למחזורית
compression_error = np.max(np.abs(y_dense - y_naive))
relative_error = np.linalg.norm(y_dense - y_naive) / np.linalg.norm(y_dense)

print("Max compression error:", compression_error)
print("Relative compression error:", relative_error)
