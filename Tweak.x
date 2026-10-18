// Icons18 v0.3 — иконки, виджеты и иконки в Настройках в стиле iOS 18 (Default / Dark / Auto / Tinted)
// для iOS 15.0–15.8.x.
//
// Как это устроено:
//  * Вход: режим редактирования рабочего стола -> «+» -> в галерее виджетов кнопка «Customize».
//    Она открывает панель: Default / Dark / Auto / Tinted, переключатель Small / Large
//    (крупные иконки без подписей), пипетка; у Tinted два слайдера: цвет и яркость цвета.
//  * Иконки на рабочем столе перекрашиваются настоящими пикселями: картинка иконки один раз
//    снимается, пересчитывается и кладётся поверх как слой ВНУТРИ самой иконки. Поэтому любые
//    копии иконки (нажатие, меню, анимации) уже цветные и не мигают стоковым цветом.
//  * Виджеты и иконки в приложении «Настройки» красятся цветовым фильтром CAFilter(colorMatrix).
//  * Выбор хранится в com.local.icons18 и сразу подхватывается и SpringBoard, и Настройками.
//  * Раздела в приложении «Настройки» нет.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

@interface SBIconImageView : UIView
@end
@interface SBIconView : UIView
@end
@interface PSTableCell : UITableViewCell
@end

#define IC_DOMAIN CFSTR("com.local.icons18")
#define IC_NOTIFY CFSTR("com.local.icons18/prefs")

// ICMATH-BEGIN  (чистый C: используется и в тестовой проверке цвета на Linux)
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

enum { ICModeDefault = 0, ICModeDark = 1, ICModeTinted = 2, ICModeAuto = 3 };

// Фон ярче порога считается «белым» (Календарь, Фото) и инвертируется.
// Цветные яркие фоны (зелёные «Сообщения») ниже порога: у них значок светлее фона.
#define IC_BRIGHT_BG 0.85
// Фон темнее порога уже тёмный: в режиме Dark такая иконка не меняется.
#define IC_DARK_BG   0.18

typedef struct { double r, g, b; } ICRGB;

static int    gMode     = ICModeDefault; // выбор пользователя (в т.ч. Auto)
static int    gEff      = ICModeDefault; // что реально применяется: Default / Dark / Tinted
static double gColorPos = 0.62;  // 0..1, положение слайдера цвета (радуга красный..розовый)
static double gBriPos   = 0.15;  // 0..1, положение слайдера яркости (от насыщенного к белому)

static inline double ICClamp01(double x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
static inline double ICLum(ICRGB c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b; }

static ICRGB ICHSV(double h, double s, double v) {
    h = fmod(h, 360.0);
    if (h < 0) h += 360.0;
    double c = v * s, hp = h / 60.0;
    double x = c * (1.0 - fabs(fmod(hp, 2.0) - 1.0));
    double r1 = 0, g1 = 0, b1 = 0;
    if      (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else             { r1 = c; b1 = x; }
    double m = v - c;
    ICRGB o = {r1 + m, g1 + m, b1 + m};
    return o;
}

// Положение слайдера цвета -> оттенок (радуга красный..розовый, как в видео).
static void ICColorFromPos(double p, double *hue, double *sat) {
    p = ICClamp01(p);
    *sat = 1.0;
    *hue = p * 340.0;
}

// Слайдер яркости: слева насыщенный цвет, справа почти белый (как в видео).
static ICRGB ICTintColor(double colorPos, double briPos) {
    double h, s;
    ICColorFromPos(colorPos, &h, &s);
    double b = ICClamp01(briPos);
    return ICHSV(h, 0.85 - 0.77 * b, 1.0);
}

// Дуотон: яркость пикселя -> градиент от тёмного цвета d к цвету t.
// Фон иконки (bgLum) становится d, самое светлое (или самое тёмное, если inverted) — t.
static void ICDuotone(float *m, const double *t, const double *d, double bgLum, int inverted) {
    static const double L[3] = {0.2126, 0.7152, 0.0722};
    double a, b;
    if (inverted) {              // светлый фон с тёмным рисунком
        double bb = bgLum > 0.5 ? bgLum : 0.5;
        a = -1.0 / bb;
        b = 1.0;
    } else {                     // цветной/тёмный фон со светлым значком
        double bb = bgLum < IC_BRIGHT_BG ? bgLum : IC_BRIGHT_BG;
        a = 1.0 / (1.0 - bb);
        b = -bb * a;
    }
    for (int c = 0; c < 3; c++) {
        double k = t[c] - d[c];
        for (int j = 0; j < 3; j++) m[c * 5 + j] = (float)(k * a * L[j]);
        m[c * 5 + 4] = (float)(d[c] + k * b);
    }
}

// Матрица 4x5 (строки R,G,B,A; столбцы R,G,B,A,смещение), как CAColorMatrix.
static void ICBuildMatrix(float *m, ICRGB bg) {
    memset(m, 0, 20 * sizeof(float));
    m[18] = 1.0f; // альфа без изменений
    double bgLum = ICLum(bg);
    int veryDark = bgLum < IC_DARK_BG;
    int bright   = bgLum > IC_BRIGHT_BG;

    if (gEff == ICModeDark) {
        if (veryDark) {                       // уже тёмная иконка — оставляем
            m[0] = m[6] = m[12] = 1.0f;
            return;
        }
        if (bright) {
            // invert + hue-rotate(180°): белый фон -> тёмно-серый, оттенки рисунка сохраняются
            static const double H[3][3] = {
                {-0.574, 1.430,  0.144},
                { 0.426, 0.430,  0.144},
                { 0.426, 1.430, -0.856},
            };
            for (int c = 0; c < 3; c++) {
                for (int j = 0; j < 3; j++) m[c * 5 + j] = (float)(-0.85 * H[c][j]);
                m[c * 5 + 4] = 0.95f;
            }
            return;
        }
        // цветной фон: фон -> тёмный, значок -> цвета бывшего фона (как тёмные иконки в iOS 18)
        double mx = bg.r > bg.g ? bg.r : bg.g;
        if (bg.b > mx) mx = bg.b;
        if (mx < 0.05) mx = 0.05;
        double t[3] = {bg.r / mx, bg.g / mx, bg.b / mx};
        double d[3] = {0.10, 0.10, 0.10};
        ICDuotone(m, t, d, bgLum, 0);
        return;
    }

    // Tinted: тёмный фон, значок цвета с двух слайдеров
    ICRGB tc = ICTintColor(gColorPos, gBriPos);
    double t[3] = {tc.r, tc.g, tc.b};
    double d[3] = {0.06 + 0.08 * tc.r, 0.06 + 0.08 * tc.g, 0.06 + 0.08 * tc.b};
    ICDuotone(m, t, d, bgLum, bright);
}

// ---------- Анализ фона иконки ----------
typedef struct {
    ICRGB med;          // типичный цвет фона (медиана по краю)
    double medLum;      // его яркость
    int axis;           // 0: фон меняется сверху вниз, 1: слева направо
    int n;              // длина профиля (h или w)
    float prof[512][3]; // цвет фона вдоль оси (градиент)
} ICBg;

typedef struct { float l, r, g, b; } ICSample;
static int ICCmpSample(const void *a, const void *b) {
    float x = ((const ICSample *)a)->l, y = ((const ICSample *)b)->l;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static int ICEdgePx(const uint8_t *buf, int w, int x, int y, float *rgb) {
    const uint8_t *p = buf + ((size_t)y * w + x) * 4;
    if (p[3] < 230) return 0;
    float a = p[3] / 255.0f;
    rgb[0] = p[0] / 255.0f / a; rgb[1] = p[1] / 255.0f / a; rgb[2] = p[2] / 255.0f / a;
    return 1;
}

// Профиль фона вдоль оси: среднее двух противоположных краёв; пропуски заполняются ближайшими.
static int ICProfile(const uint8_t *buf, int w, int h, int vertical, float prof[][3], double *range) {
    int n = vertical ? h : w;
    int mn = w < h ? w : h;
    int ed = mn / 24 < 2 ? 2 : mn / 24;
    static const int MAXN = 512;
    if (n > MAXN) return 0;
    char ok[512];
    int cntOk = 0;
    float lo = 9, hi = -9;
    for (int i = 0; i < n; i++) {
        float a[3], b[3];
        int okA, okB;
        double f = (double)i / n;
        ok[i] = 0;
        if (f < 0.2 || f > 0.8) continue;           // углы со скруглением не берём
        if (vertical) { okA = ICEdgePx(buf, w, ed, i, a);   okB = ICEdgePx(buf, w, w - 1 - ed, i, b); }
        else          { okA = ICEdgePx(buf, w, i, ed, a);   okB = ICEdgePx(buf, w, i, h - 1 - ed, b); }
        if (!okA && !okB) continue;
        for (int c = 0; c < 3; c++) prof[i][c] = (okA && okB) ? 0.5f * (a[c] + b[c]) : (okA ? a[c] : b[c]);
        ok[i] = 1; cntOk++;
        float l = 0.2126f * prof[i][0] + 0.7152f * prof[i][1] + 0.0722f * prof[i][2];
        if (l < lo) lo = l;
        if (l > hi) hi = l;
    }
    if (cntOk < n / 4) return 0;
    int last = -1;
    for (int i = 0; i < n; i++) {                   // вперёд
        if (ok[i]) last = i; else if (last >= 0) memcpy(prof[i], prof[last], 3 * sizeof(float));
    }
    last = -1;
    for (int i = n - 1; i >= 0; i--) {              // назад
        if (ok[i]) last = i; else if (last >= 0 && !ok[i]) { if (prof[i][0] == 0 && prof[i][1] == 0 && prof[i][2] == 0) memcpy(prof[i], prof[last], 3 * sizeof(float)); }
    }
    // позиции до первой и после последней известной точки
    int first = -1;
    for (int i = 0; i < n; i++) if (ok[i]) { first = i; break; }
    for (int i = 0; i < first; i++) memcpy(prof[i], prof[first], 3 * sizeof(float));
    *range = hi - lo;
    return 1;
}

// Возвращает 1, если у картинки есть нормальный фон (непрозрачный край).
static int ICAnalyze(const uint8_t *buf, int w, int h, ICBg *bg) {
    int mn = w < h ? w : h;
    int ed = mn / 24 < 2 ? 2 : mn / 24;

    // медиана яркости по краевому кольцу (без углов)
    ICSample s[2048];
    int cnt = 0;
    for (int y = 0; y < h && cnt < 2040; y++) {
        for (int x = 0; x < w && cnt < 2040; x++) {
            int e = x < y ? x : y;
            if (w - 1 - x < e) e = w - 1 - x;
            if (h - 1 - y < e) e = h - 1 - y;
            if (e != ed) continue;
            double fx = (double)x / w, fy = (double)y / h;
            if ((fx < 0.2 || fx > 0.8) && (fy < 0.2 || fy > 0.8)) continue;
            float rgb[3];
            if (!ICEdgePx(buf, w, x, y, rgb)) continue;
            s[cnt].r = rgb[0]; s[cnt].g = rgb[1]; s[cnt].b = rgb[2];
            s[cnt].l = 0.2126f * rgb[0] + 0.7152f * rgb[1] + 0.0722f * rgb[2];
            cnt++;
        }
    }
    int minCnt = w / 4 < 12 ? 12 : w / 4;
    if (cnt < minCnt) return 0;
    qsort(s, cnt, sizeof(ICSample), ICCmpSample);
    float med = s[cnt / 2].l;
    double sr = 0, sg = 0, sb = 0; int k = 0;
    for (int i = 0; i < cnt; i++) {
        if (fabsf(s[i].l - med) <= 0.10f) { sr += s[i].r; sg += s[i].g; sb += s[i].b; k++; }
    }
    if (k == 0) return 0;
    bg->med.r = sr / k; bg->med.g = sg / k; bg->med.b = sb / k;
    bg->medLum = ICLum(bg->med);

    // профиль для градиентного фона: по той оси, где фон меняется сильнее
    double rv = 0, rh = 0;
    static float pv[512][3], ph[512][3];
    int okV = ICProfile(buf, w, h, 1, pv, &rv);
    int okH = ICProfile(buf, w, h, 0, ph, &rh);
    if (okV && (!okH || rv >= rh)) {
        bg->axis = 0; bg->n = h; memcpy(bg->prof, pv, sizeof(float) * 3 * h);
    } else if (okH) {
        bg->axis = 1; bg->n = w; memcpy(bg->prof, ph, sizeof(float) * 3 * w);
    } else {
        bg->axis = 0; bg->n = h;
        for (int i = 0; i < h; i++) { bg->prof[i][0] = bg->med.r; bg->prof[i][1] = bg->med.g; bg->prof[i][2] = bg->med.b; }
    }
    return 1;
}

static int ICBackgroundOf(const uint8_t *buf, int w, int h, ICRGB *out) {
    ICBg bg;
    if (!ICAnalyze(buf, w, h, &bg)) return 0;
    *out = bg.med;
    return 1;
}

static inline float ICSmooth(float e0, float e1, float x) {
    float t = (x - e0) / (e1 - e0);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
}

// Пересчёт всех пикселей иконки. Вход и выход: RGBA8, premultiplied alpha.
// «Чернила» (ink) — насколько пиксель отличается по цвету от фона в этой точке: фон -> 0, значок -> 1.
// Так значок отделяется от фона и на светлом, и на тёмном, и на градиентном фоне.
static void ICProcessIcon(const uint8_t *src, uint8_t *dst, int w, int h, const ICBg *bg) {
    int bright   = bg->medLum > IC_BRIGHT_BG;
    int veryDark = bg->medLum < IC_DARK_BG;
    double mx = bg->med.r > bg->med.g ? bg->med.r : bg->med.g;
    if (bg->med.b > mx) mx = bg->med.b;
    if (mx < 0.05) mx = 0.05;
    float boost[3] = {(float)(bg->med.r / mx), (float)(bg->med.g / mx), (float)(bg->med.b / mx)};

    ICRGB tc = ICTintColor(gColorPos, gBriPos);
    float t[3] = {(float)tc.r, (float)tc.g, (float)tc.b};
    float dT[3] = {0.06f + 0.08f * t[0], 0.06f + 0.08f * t[1], 0.06f + 0.08f * t[2]};
    float dD[3] = {0.10f, 0.10f, 0.11f};

    // 1) «чернила» по цветовому расстоянию до фона в этой точке
    long total = (long)w * h;
    float *inkArr = (float *)malloc(sizeof(float) * total);
    uint8_t *bgLike = (uint8_t *)calloc(total, 1);
    uint8_t *glyph = (uint8_t *)calloc(total, 1);
    int *queue = (int *)malloc(sizeof(int) * total);
    if (!inkArr || !bgLike || !glyph || !queue) {
        free(inkArr); free(bgLike); free(glyph); free(queue);
        memcpy(dst, src, (size_t)total * 4);
        return;
    }
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            long i = (long)y * w + x;
            const uint8_t *s = src + i * 4;
            if (s[3] == 0) { inkArr[i] = 0; continue; }
            float a = s[3] / 255.0f;
            float p0 = s[0] / 255.0f / a, p1 = s[1] / 255.0f / a, p2 = s[2] / 255.0f / a;
            const float *ref = bg->prof[bg->axis == 0 ? y : x];
            float dr = p0 - ref[0], dg = p1 - ref[1], db = p2 - ref[2];
            float dist = sqrtf(dr * dr + dg * dg + db * db);
            inkArr[i] = ICSmooth(0.07f, 0.38f, dist);
            bgLike[i] = dist < 0.16f;
        }
    }
    // 2) области, похожие на фон: фон — это то, что касается края или достаточно велико;
    //    маленькие «островки» внутри значка (белое кольцо вокруг точки) — часть значка
    {
        int mn = w < h ? w : h;
        int edgeBand = (mn / 24 < 2 ? 2 : mn / 24) + 1;
        long bigArea = total * 4 / 100;
        uint8_t *seen = (uint8_t *)calloc(total, 1);
        if (seen) {
            for (long st = 0; st < total; st++) {
                if (!bgLike[st] || seen[st]) continue;
                long head = 0, tail = 0;
                int touches = 0;
                queue[tail++] = (int)st; seen[st] = 1;
                while (head < tail) {
                    int cur = queue[head++];
                    int cx = cur % w, cy = cur / w;
                    if (cx < edgeBand || cy < edgeBand || cx >= w - edgeBand || cy >= h - edgeBand) touches = 1;
                    static const int dx[4] = {1, -1, 0, 0}, dy[4] = {0, 0, 1, -1};
                    for (int k = 0; k < 4; k++) {
                        int nx = cx + dx[k], ny = cy + dy[k];
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        long ni = (long)ny * w + nx;
                        if (bgLike[ni] && !seen[ni]) { seen[ni] = 1; queue[tail++] = (int)ni; }
                    }
                }
                if (!touches && tail < bigArea) {
                    for (long q = 0; q < tail; q++) glyph[queue[q]] = 1;
                }
            }
            free(seen);
        }
    }
    free(queue);

    // 3) итоговый пересчёт
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            long i = (long)y * w + x;
            const uint8_t *s = src + i * 4;
            uint8_t *d = dst + i * 4;
            if (s[3] == 0) { d[0] = d[1] = d[2] = d[3] = 0; continue; }
            float a = s[3] / 255.0f;
            float p[3] = {s[0] / 255.0f / a, s[1] / 255.0f / a, s[2] / 255.0f / a};
            for (int c = 0; c < 3; c++) if (p[c] > 1) p[c] = 1;
            const float *ref = bg->prof[bg->axis == 0 ? y : x];
            float ink = inkArr[i];
            if (glyph[i] && ink < 0.9f) ink = 0.9f;
            float lum = 0.2126f * p[0] + 0.7152f * p[1] + 0.0722f * p[2];
            float refLum = 0.2126f * ref[0] + 0.7152f * ref[1] + 0.0722f * ref[2];
            float o[3];

            if (gEff == ICModeDark) {
                if (veryDark) { o[0] = p[0]; o[1] = p[1]; o[2] = p[2]; }
                else {
                    float mxp = p[0] > p[1] ? p[0] : p[1]; if (p[2] > mxp) mxp = p[2];
                    float mnp = p[0] < p[1] ? p[0] : p[1]; if (p[2] < mnp) mnp = p[2];
                    float chroma = mxp - mnp;
                    float keep = ICSmooth(0.15f, 0.40f, chroma);   // яркие цвета значка остаются как есть
                    float g[3];
                    for (int c = 0; c < 3; c++) {
                        float low;
                        if (bright) {                               // тёмный рисунок на белом -> светлый,
                            float wl = ICSmooth(0.45f, 0.65f, lum); // а светлые детали внутри значка остаются
                            low = (1.0f - lum) + (lum - (1.0f - lum)) * wl;
                        }
                        else        low = lum * boost[c];           // белый значок на цвете -> цвет фона
                        g[c] = low + (p[c] - low) * keep;
                    }
                    for (int c = 0; c < 3; c++) o[c] = dD[c] + (g[c] - dD[c]) * ink;
                }
            } else {
                float L;
                if (bright) { L = (refLum - lum) / (refLum > 0.3f ? refLum : 0.3f); }
                else        { L = (lum - refLum) / (1.0f - refLum > 0.2f ? 1.0f - refLum : 0.2f); }
                L = L < 0 ? 0 : (L > 1 ? 1 : L);
                float gb = ink * (0.6f + 0.4f * L);
                for (int c = 0; c < 3; c++) o[c] = dT[c] + gb * (t[c] - dT[c]);
            }
            for (int c = 0; c < 3; c++) { o[c] = o[c] < 0 ? 0 : (o[c] > 1 ? 1 : o[c]); d[c] = (uint8_t)(o[c] * a * 255.0f + 0.5f); }
            d[3] = s[3];
        }
    }
    free(inkArr); free(bgLike); free(glyph);
}
// ICMATH-END

static char kSigKey, kTriesKey, kOverlayKey, kGenKey;
static NSString *const kFilterName  = @"icons18";
static NSString *const kOverlayName = @"icons18-overlay";
static NSInteger gGen = 1;                                   // растёт при каждом изменении настроек
static int gSize = 0;        // 0 = Small, 1 = Large (крупные иконки без подписей)
static int gAutoStyle = 0;   // для Auto: 0 как в системе, 1 светлый, 2 тёмный
static NSMutableDictionary<NSString *, NSDictionary *> *gSrcCache; // bundleID -> {data,w,h}
static NSSet<NSString *> *gDynamicIdents;                    // иконки, которые рисуются «вживую»
static NSHashTable<UIView *> *gIconViews;     // SBIconImageView
static NSHashTable<UIView *> *gIconCells;     // SBIconView (для размера)
static NSHashTable<UIView *> *gDynViews;      // «живые» иконки (часы, календарь)
static NSHashTable<UIView *> *gWidgetViews;   // содержимое виджетов
static NSHashTable<UIView *> *gSettingsViews; // иконки в ячейках Настроек
static int gLogBudget = 10;

static UIColor *ICUIColor(ICRGB c) {
    return [UIColor colorWithRed:c.r green:c.g blue:c.b alpha:1.0];
}

// =====================================================================================
#pragma mark - Настройки (com.local.icons18)
// =====================================================================================

static id ICPref(NSString *key) {
    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, IC_DOMAIN);
}

// Какой режим реально применять: Auto -> светлый или тёмный по теме системы (или по выбору солнца)
static int ICComputeEff(void) {
    if (gMode != ICModeAuto) return gMode;
    BOOL dark;
    if (gAutoStyle == 1) dark = NO;
    else if (gAutoStyle == 2) dark = YES;
    else dark = [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return dark ? ICModeDark : ICModeDefault;
}

// возвращает YES, если реальный режим изменился
static BOOL ICSyncEff(void) {
    int e = ICComputeEff();
    if (e == gEff) return NO;
    gEff = e;
    gGen++;
    return YES;
}

// возвращает YES, если значения изменились
static BOOL ICLoad(void) {
    CFPreferencesAppSynchronize(IC_DOMAIN);
    id v;
    v = ICPref(@"mode");      int    m  = v ? MIN(MAX([v intValue], 0), 3) : ICModeDefault;
    v = ICPref(@"colorPos");  double cp = v ? ICClamp01([v doubleValue]) : 0.62;
    v = ICPref(@"briPos");    double bp = v ? ICClamp01([v doubleValue]) : 0.15;
    v = ICPref(@"size");      int    sz = v ? MIN(MAX([v intValue], 0), 1) : 0;
    v = ICPref(@"autoStyle"); int    as = v ? MIN(MAX([v intValue], 0), 2) : 0;
    BOOL changed = (m != gMode) || (sz != gSize) || (as != gAutoStyle) ||
                   fabs(cp - gColorPos) > 1e-6 || fabs(bp - gBriPos) > 1e-6;
    gMode = m; gColorPos = cp; gBriPos = bp; gSize = sz; gAutoStyle = as;
    if (changed) gGen++;
    BOOL eff = ICSyncEff();
    return changed || eff;
}

static void ICSave(void) {
    CFPreferencesSetAppValue(CFSTR("mode"),      (__bridge CFTypeRef)@(gMode),      IC_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("colorPos"),  (__bridge CFTypeRef)@(gColorPos),  IC_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("briPos"),    (__bridge CFTypeRef)@(gBriPos),    IC_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("size"),      (__bridge CFTypeRef)@(gSize),      IC_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("autoStyle"), (__bridge CFTypeRef)@(gAutoStyle), IC_DOMAIN);
    CFPreferencesAppSynchronize(IC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         IC_NOTIFY, NULL, NULL, YES);
}

// =====================================================================================
#pragma mark - Фильтр на слое (виджеты, иконки в Настройках, запасной вариант)
// =====================================================================================

static id ICMakeFilter(const float *m) {
    Class cls = NSClassFromString(@"CAFilter");
    if (!cls) return nil;
    id f = ((id (*)(Class, SEL, NSString *))objc_msgSend)(cls, NSSelectorFromString(@"filterWithType:"), @"colorMatrix");
    if (!f) return nil;
    NSValue *val = [NSValue valueWithBytes:m objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    @try {
        [f setValue:val forKey:@"inputColorMatrix"];
        [f setValue:kFilterName forKey:@"name"];
    } @catch (NSException *e) {
        NSLog(@"[Icons18] ERROR: CAFilter setValue failed: %@", e);
        return nil;
    }
    return f;
}

static BOOL ICIsOurFilter(id f) {
    id n = nil;
    @try { n = [f valueForKey:@"name"]; } @catch (NSException *e) {}
    return [n isEqual:kFilterName];
}

static void ICRemoveOurFilters(CALayer *layer) {
    NSArray *fs = layer.filters;
    if (!fs.count) return;
    NSMutableArray *keep = [NSMutableArray array];
    for (id f in fs) if (!ICIsOurFilter(f)) [keep addObject:f];
    if (keep.count != fs.count) layer.filters = keep.count ? keep : nil;
}

static BOOL ICHasOurFilter(CALayer *layer) {
    for (id f in layer.filters) if (ICIsOurFilter(f)) return YES;
    return NO;
}

static void ICClearFilter(UIView *v) {
    ICRemoveOurFilters(v.layer);
    objc_setAssociatedObject(v, &kSigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ICInstallFilter(UIView *v, ICRGB bg) {
    float m[20];
    ICBuildMatrix(m, bg);
    NSData *sig = [NSData dataWithBytes:m length:sizeof(m)];
    NSData *old = objc_getAssociatedObject(v, &kSigKey);
    if (old && [old isEqualToData:sig] && ICHasOurFilter(v.layer)) return; // уже стоит такой же

    id f = ICMakeFilter(m);
    if (!f) return;
    ICRemoveOurFilters(v.layer);
    NSMutableArray *arr = [NSMutableArray arrayWithArray:v.layer.filters ?: @[]];
    [arr addObject:f];
    v.layer.filters = arr;
    objc_setAssociatedObject(v, &kSigKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// =====================================================================================
#pragma mark - Снимок пикселей вида
// =====================================================================================

static CGContextRef ICMakeCtx(uint8_t *buf, int w, int h, CGFloat scale) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextTranslateCTM(ctx, 0, h);           // как в UIKit: начало координат слева сверху
    CGContextScaleCTM(ctx, scale, -scale);
    return ctx;
}

// Возвращает RGBA8 (premultiplied) картинки вида в реальном разрешении экрана или nil.
static NSData *ICCapture(UIView *v, int *outW, int *outH, BOOL allowHierarchy) {
    CGSize s = v.bounds.size;
    if (s.width < 10 || s.height < 10) return nil;
    CGFloat scale = v.window.screen.scale;
    if (scale < 1) scale = [UIScreen mainScreen].scale;
    if (scale < 1) scale = 1;
    int w = (int)lround(s.width * scale), h = (int)lround(s.height * scale);
    if (w > 400 || h > 400) return nil;

    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
    ICRGB bg;

    // способ 1: рендер слоя (работает, если картинка лежит в layer.contents как CGImage)
    CGContextRef ctx = ICMakeCtx(buf.mutableBytes, w, h, scale);
    if (!ctx) return nil;
    [v.layer renderInContext:ctx];
    CGContextRelease(ctx);
    if (ICBackgroundOf(buf.bytes, w, h, &bg)) { *outW = w; *outH = h; return buf; }

    // способ 2: снимок того, что реально нарисовано на экране
    if (!allowHierarchy || !v.window) return nil;
    memset(buf.mutableBytes, 0, buf.length);
    ctx = ICMakeCtx(buf.mutableBytes, w, h, scale);
    if (!ctx) return nil;
    UIGraphicsPushContext(ctx);
    [v drawViewHierarchyInRect:CGRectMake(0, 0, s.width, s.height) afterScreenUpdates:NO];
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    if (ICBackgroundOf(buf.bytes, w, h, &bg)) { *outW = w; *outH = h; return buf; }
    return nil;
}

// =====================================================================================
#pragma mark - Поиск иконки / виджета
// =====================================================================================

static id ICMsg0(id obj, NSString *sel) {   // только для методов, возвращающих объект
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static NSString *ICIdentifierOfIcon(id icon) {
    if (!icon) return nil;
    for (NSString *name in @[@"applicationBundleID", @"nodeIdentifier", @"uniqueIdentifier", @"leafIdentifier"]) {
        id r = ICMsg0(icon, name);
        if ([r isKindOfClass:[NSString class]] && [r length]) return r;
    }
    return nil;
}

static BOOL ICIconIsWidget(id icon) {
    return icon && [NSStringFromClass([icon class]) containsString:@"Widget"];
}

static BOOL ICIsFolderImage(UIView *v) {
    Class c = NSClassFromString(@"SBFolderIconImageView");
    return c && [v isKindOfClass:c];
}

static BOOL ICIsInsideWidget(UIView *v) {
    Class ivc = NSClassFromString(@"SBIconView");
    if (!ivc) return NO;
    for (UIView *p = v; p; p = p.superview) {
        if ([p isKindOfClass:ivc]) return ICIconIsWidget(ICMsg0(p, @"icon"));
    }
    return NO;
}

static UIView *ICWidgetContentOf(UIView *iconView) {
    id c = ICMsg0(iconView, @"iconImageView");
    if (!c) {
        @try { c = [iconView valueForKey:@"_iconImageView"]; } @catch (NSException *e) {}
    }
    return [c isKindOfClass:[UIView class]] ? c : nil;
}

// =====================================================================================
#pragma mark - Перекраска иконок рабочего стола (слой с пересчитанными пикселями)
// =====================================================================================

// Вид, на котором лежит сама картинка иконки: крупный UIImageView внутри SBIconImageView.
// Слой кладём внутрь него, чтобы нажатие, затемнение и анимации действовали и на наш слой.
static UIView *ICContentHost(UIView *v) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    CGSize vs = v.bounds.size;
    for (UIView *sv in v.subviews) {
        if (![sv isKindOfClass:[UIImageView class]]) continue;
        CGSize z = sv.bounds.size;
        if (z.width < vs.width * 0.8 || z.height < vs.height * 0.8) continue;
        if (z.width * z.height > bestArea) { best = sv; bestArea = z.width * z.height; }
    }
    return best ?: v;
}

static void ICRemoveOverlay(UIView *v) {
    CALayer *ov = objc_getAssociatedObject(v, &kOverlayKey);
    if (ov) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [ov removeFromSuperlayer];
        [CATransaction commit];
    }
    objc_setAssociatedObject(v, &kGenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ICSetOverlay(UIView *v, UIView *host, CGImageRef img, CGFloat scale) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *ov = objc_getAssociatedObject(v, &kOverlayKey);
    if (!ov) {
        ov = [CALayer layer];
        ov.name = kOverlayName;
        ov.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null],
                       @"position": [NSNull null], @"hidden": [NSNull null]};
        objc_setAssociatedObject(v, &kOverlayKey, ov, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ov.superlayer != host.layer || host.layer.sublayers.lastObject != ov) {
        [ov removeFromSuperlayer];
        [host.layer addSublayer:ov];
    }
    ov.frame = host.layer.bounds;
    ov.contentsScale = scale;
    ov.contents = (__bridge id)img;
    ov.hidden = NO;
    [CATransaction commit];
}

static void ICSetOverlayHidden(UIView *v, BOOL hidden) {
    CALayer *ov = objc_getAssociatedObject(v, &kOverlayKey);
    if (!ov) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ov.hidden = hidden;
    [CATransaction commit];
}

static CGImageRef ICCreateImage(NSData *px, int w, int h) {   // копирует данные
    NSData *copy = [px copy];
    CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)copy);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
                                   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
                                   p, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(p);
    return img;
}

static ICRGB ICEstimatedWidgetBg(UIView *v) {
    BOOL dark = v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    ICRGB c = dark ? (ICRGB){0.11, 0.11, 0.12} : (ICRGB){0.97, 0.97, 0.97};
    return c;
}

static void ICApplyWidgetContent(UIView *v) {
    if (gEff == ICModeDefault) { ICClearFilter(v); return; }
    // у виджета контент рисуется удалённо, снять его пиксели нельзя — берём по теме оформления
    ICInstallFilter(v, ICEstimatedWidgetBg(v));
}

static NSTimer *gDynTimer;
static void ICApplyIcon(UIView *v, BOOL force);

static void ICUpdateDynTimer(void) {
    BOOL need = (gEff != ICModeDefault) && gDynViews.count > 0;
    if (need && !gDynTimer) {
        gDynTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            for (UIView *v in gDynViews.allObjects) if (v.window) ICApplyIcon(v, YES);
        }];
    } else if (!need && gDynTimer) {
        [gDynTimer invalidate];
        gDynTimer = nil;
    }
}

static void ICApplyIcon(UIView *v, BOOL force) {
    if (gEff == ICModeDefault || ICIsFolderImage(v)) {
        ICClearFilter(v);
        ICRemoveOverlay(v);
        return;
    }
    if (ICIsInsideWidget(v)) {
        ICRemoveOverlay(v);
        ICApplyWidgetContent(v);
        return;
    }

    NSString *ident = ICIdentifierOfIcon(ICMsg0(v, @"icon"));
    BOOL dynamic = ident && [gDynamicIdents containsObject:ident];
    UIView *host = ICContentHost(v);
    CALayer *ov = objc_getAssociatedObject(v, &kOverlayKey);

    // быстрый выход: слой уже стоит и соответствует текущим настройкам
    if (!force && ov && !ov.hidden && ov.superlayer == host.layer &&
        [objc_getAssociatedObject(v, &kGenKey) isEqual:@(gGen)]) {
        if (host.layer.sublayers.lastObject != ov || !CGRectEqualToRect(ov.frame, host.layer.bounds)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (host.layer.sublayers.lastObject != ov) { [ov removeFromSuperlayer]; [host.layer addSublayer:ov]; }
            ov.frame = host.layer.bounds;
            [CATransaction commit];
        }
        return;
    }

    // исходные пиксели иконки (без нашего слоя и фильтра)
    NSData *src = nil;
    int w = 0, h = 0;
    NSDictionary *entry = (!dynamic && ident && !force) ? gSrcCache[ident] : nil;
    if (entry) {
        src = entry[@"d"]; w = [entry[@"w"] intValue]; h = [entry[@"h"] intValue];
    } else {
        ICSetOverlayHidden(v, YES);
        ICRemoveOurFilters(v.layer);
        src = ICCapture(v, &w, &h, /*allowHierarchy*/ !ov);
        if (!src) ICSetOverlayHidden(v, NO);          // не вышло — оставляем прежний слой
        if (src && ident && !dynamic) gSrcCache[ident] = @{@"d": src, @"w": @(w), @"h": @(h)};
    }

    ICBg bg;
    if (src && ICAnalyze(src.bytes, w, h, &bg)) {
        NSMutableData *dst = [NSMutableData dataWithLength:src.length];
        ICProcessIcon(src.bytes, dst.mutableBytes, w, h, &bg);
        CGImageRef img = ICCreateImage(dst, w, h);
        if (img) {
            CGFloat scale = v.window.screen.scale;
            if (scale < 1) scale = [UIScreen mainScreen].scale;
            ICSetOverlay(v, host, img, scale);
            CGImageRelease(img);
            ICClearFilter(v);
            objc_setAssociatedObject(v, &kGenKey, @(gGen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (dynamic) { [gDynViews addObject:v]; ICUpdateDynTimer(); }
            if (gLogBudget > 0) {
                gLogBudget--;
                NSLog(@"[Icons18] icon %@ %dx%d bg=(%.2f %.2f %.2f) mode=%d",
                      ident ?: @"(no id)", w, h, bg.med.r, bg.med.g, bg.med.b, gEff);
            }
            return;
        }
    }
    if (ov && force) return;   // обновление «живой» иконки не удалось — не трогаем текущий слой

    // запасной вариант: цветовой фильтр на слое с примерной оценкой фона
    ICRemoveOverlay(v);
    ICInstallFilter(v, (ICRGB){0.5, 0.5, 0.5});
    if (gLogBudget > 0) {
        gLogBudget--;
        NSLog(@"[Icons18] icon %@: no pixels, using filter fallback", ident ?: @"(no id)");
    }
    int tries = [objc_getAssociatedObject(v, &kTriesKey) intValue];
    if (tries < 4) {
        objc_setAssociatedObject(v, &kTriesKey, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *wv = v;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *sv = wv;
            if (sv) ICApplyIcon(sv, NO);
        });
    }
}

// Иконка в строке Настроек (картинка 29x29 у ячейки)
static void ICApplySettings(UIImageView *iv) {
    CGSize s = iv.bounds.size;
    BOOL iconLike = iv.image && s.width >= 20 && s.width <= 40 && fabs(s.width - s.height) < 2;
    if (gEff == ICModeDefault || !iconLike) { ICClearFilter(iv); return; }

    static char kImgBg;
    ICRGB bg;
    NSArray<NSNumber *> *cached = objc_getAssociatedObject(iv.image, &kImgBg);
    if (cached) {
        bg = (ICRGB){[cached[0] doubleValue], [cached[1] doubleValue], [cached[2] doubleValue]};
    } else {
        ICRemoveOurFilters(iv.layer);
        int w = 0, h = 0;
        NSData *px = ICCapture(iv, &w, &h, NO);
        if (!px || !ICBackgroundOf(px.bytes, w, h, &bg)) { ICClearFilter(iv); return; }
        objc_setAssociatedObject(iv.image, &kImgBg, @[@(bg.r), @(bg.g), @(bg.b)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ICInstallFilter(iv, bg);
}

// =====================================================================================
#pragma mark - Размер иконок: Small / Large (крупные и без подписей)
// =====================================================================================

#define IC_LARGE_SCALE 1.2
static char kLabelsHiddenKey;

static BOOL ICCellIsHomeIcon(UIView *cell) {
    id loc = ICMsg0(cell, @"location");
    if ([loc isKindOfClass:[NSString class]]) {
        NSString *l = loc;
        for (NSString *bad in @[@"Dock", @"Folder", @"Switcher", @"Library", @"Spotlight", @"Today", @"Preview"]) {
            if ([l containsString:bad]) return NO;
        }
    }
    return !ICIconIsWidget(ICMsg0(cell, @"icon"));
}

static NSArray<UIView *> *ICLabelViewsOf(UIView *cell) {
    NSMutableArray *a = [NSMutableArray array];
    for (UIView *sv in cell.subviews) {
        if ([NSStringFromClass([sv class]) containsString:@"Label"]) [a addObject:sv];
    }
    return a;
}

static void ICApplySize(UIView *cell) {
    BOOL want = (gSize == 1) && ICCellIsHomeIcon(cell);
    CATransform3D t = CATransform3DIdentity;
    if (want) {
        UIView *img = ICWidgetContentOf(cell);
        CGFloat H = cell.bounds.size.height;
        CGFloat c = (img && img.superview == cell) ? CGRectGetMidY(img.frame) : H / 2;
        CGFloat ty = IC_LARGE_SCALE * (H / 2 - c);     // значок остаётся по центру ячейки
        t = CATransform3DConcat(CATransform3DMakeScale(IC_LARGE_SCALE, IC_LARGE_SCALE, 1),
                                CATransform3DMakeTranslation(0, ty, 0));
    }
    if (!CATransform3DEqualToTransform(cell.layer.sublayerTransform, t)) cell.layer.sublayerTransform = t;

    BOOL hidNow = [objc_getAssociatedObject(cell, &kLabelsHiddenKey) boolValue];
    if (want) {
        for (UIView *lv in ICLabelViewsOf(cell)) if (lv.alpha != 0) lv.alpha = 0;
        if (!hidNow) objc_setAssociatedObject(cell, &kLabelsHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (hidNow) {
        for (UIView *lv in ICLabelViewsOf(cell)) lv.alpha = 1;
        objc_setAssociatedObject(cell, &kLabelsHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ICRefreshAll(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ICRefreshAll(); });
        return;
    }
    ICSyncEff();
    for (UIView *v in gIconViews.allObjects)     ICApplyIcon(v, NO);
    for (UIView *v in gWidgetViews.allObjects)   ICApplyWidgetContent(v);
    for (UIView *v in gSettingsViews.allObjects) ICApplySettings((UIImageView *)v);
    for (UIView *v in gIconCells.allObjects)     ICApplySize(v);
    ICUpdateDynTimer();
}

static void ICPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    if (ICLoad()) ICRefreshAll();
}

// =====================================================================================
#pragma mark - Панель Customize: превью варианта (значок «Погода», как в видео)
// =====================================================================================

static UIBezierPath *ICCloudPath(CGFloat u) {
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(.20 * u, .52 * u, .64 * u, .24 * u) cornerRadius:.12 * u];
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(.28 * u, .38 * u, .28 * u, .28 * u)]];
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(.45 * u, .30 * u, .34 * u, .34 * u)]];
    return p;
}

static void ICFillGradient(CGContextRef c, CGRect r, UIColor *top, UIColor *bot) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = @[(id)top.CGColor, (id)bot.CGColor];
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
    if (g) {
        CGContextDrawLinearGradient(c, g, CGPointMake(0, r.origin.y), CGPointMake(0, CGRectGetMaxY(r)), 0);
        CGGradientRelease(g);
    }
    CGColorSpaceRelease(cs);
}

// style: 0 светлый, 1 тёмный, 2 цветной (Tinted)
static void ICDrawWeatherVariant(CGContextRef c, CGFloat u, int style, ICRGB t) {
    CGRect r = CGRectMake(0, 0, u, u);
    UIColor *sun, *cloud;
    if (style == 0) {
        ICFillGradient(c, r, [UIColor colorWithRed:.27 green:.58 blue:1 alpha:1], [UIColor colorWithRed:.58 green:.82 blue:1 alpha:1]);
        sun = [UIColor colorWithRed:1 green:.82 blue:.20 alpha:1];
        cloud = [UIColor whiteColor];
    } else if (style == 1) {
        ICFillGradient(c, r, [UIColor colorWithRed:.22 green:.22 blue:.23 alpha:1], [UIColor colorWithRed:.12 green:.12 blue:.13 alpha:1]);
        sun = [UIColor colorWithRed:1 green:.80 blue:.28 alpha:1];
        cloud = [UIColor colorWithRed:.80 green:.80 blue:.84 alpha:1];
    } else {
        ICRGB d = {0.06 + 0.08 * t.r, 0.06 + 0.08 * t.g, 0.06 + 0.08 * t.b};
        ICFillGradient(c, r, ICUIColor((ICRGB){d.r + 0.03, d.g + 0.03, d.b + 0.03}), ICUIColor(d));
        sun = ICUIColor((ICRGB){t.r * 0.8, t.g * 0.8, t.b * 0.8});
        cloud = ICUIColor(t);
    }
    [sun setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(.14 * u, .20 * u, .34 * u, .34 * u)] fill];
    [cloud setFill];
    [ICCloudPath(u) fill];
}

@interface ICPreviewView : UIView
@property (nonatomic) int mode;
@property (nonatomic) BOOL chosen;
- (void)refresh;
@end

@implementation ICPreviewView

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.cornerRadius = f.size.width * 0.225;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refresh];
}

- (void)refresh {
    CGSize size = self.bounds.size;
    if (size.width < 4) return;
    ICRGB t = ICTintColor(gColorPos, gBriPos);
    int mode = _mode;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGFloat u = size.width;
        if (mode == ICModeAuto) {
            ICDrawWeatherVariant(c, u, 0, t);
            CGContextSaveGState(c);
            CGContextMoveToPoint(c, 0, u);
            CGContextAddLineToPoint(c, u, 0);
            CGContextAddLineToPoint(c, u, u);
            CGContextClosePath(c);
            CGContextClip(c);
            ICDrawWeatherVariant(c, u, 1, t);
            CGContextRestoreGState(c);
        } else {
            ICDrawWeatherVariant(c, u, mode == ICModeDefault ? 0 : (mode == ICModeDark ? 1 : 2), t);
        }
    }];
    self.layer.contents = (__bridge id)img.CGImage;
    self.layer.contentsScale = img.scale;
    self.layer.borderWidth = _chosen ? 2.5 : 0.0;
    self.layer.borderColor = [[UIColor labelColor] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}
@end

// =====================================================================================
#pragma mark - Панель Customize: слайдер с градиентом и круглым ползунком
// =====================================================================================

static UIImage *ICThumbImage(UIColor *fill) {
    CGFloat d = 34;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGContextSetShadowWithColor(c, CGSizeMake(0, 1), 2, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(c, CGRectInset(CGRectMake(0, 0, d, d), 1, 1));
        CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
        [fill setFill];
        CGContextFillEllipseInRect(c, CGRectInset(CGRectMake(0, 0, d, d), 5, 5));
    }];
}

@interface ICSliderRow : UIView
@property (nonatomic, strong, readonly) UISlider *slider;
@property (nonatomic, strong, readonly) CAGradientLayer *gradient;
- (void)setThumbColor:(UIColor *)c;
@end

@implementation ICSliderRow {
    UIView *_track;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _track = [UIView new];
        _track.layer.cornerRadius = 14;
        _track.layer.cornerCurve = kCACornerCurveContinuous;
        _track.layer.masksToBounds = YES;
        _gradient = [CAGradientLayer layer];
        _gradient.startPoint = CGPointMake(0, 0.5);
        _gradient.endPoint = CGPointMake(1, 0.5);
        [_track.layer addSublayer:_gradient];
        [self addSubview:_track];

        _slider = [UISlider new];
        _slider.minimumValue = 0;
        _slider.maximumValue = 1;
        _slider.minimumTrackTintColor = [UIColor clearColor];
        _slider.maximumTrackTintColor = [UIColor clearColor];
        [self addSubview:_slider];
    }
    return self;
}

- (void)setThumbColor:(UIColor *)c {
    UIImage *img = ICThumbImage(c);
    [_slider setThumbImage:img forState:UIControlStateNormal];
    [_slider setThumbImage:img forState:UIControlStateHighlighted];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _track.frame = CGRectMake(0, (h - 28) / 2, w, 28);
    _gradient.frame = _track.bounds;
    _slider.frame = CGRectMake(0, 0, w, h);
}
@end

// =====================================================================================
#pragma mark - Панель Customize
// =====================================================================================

#define IC_TILE 64.0

static CGSize ICScreenSize(void) {
    UIScreen *s = [UIScreen mainScreen];
    return CGSizeMake(s.nativeBounds.size.width / s.scale, s.nativeBounds.size.height / s.scale);
}

static void ICHidePanel(void);
static UIWindow *gPickWin;

// выбранный в пипетке цвет -> положения двух слайдеров
static void ICSetFromUIColor(UIColor *c) {
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) return;
    double hd = h * 360.0;
    if (hd > 340.0) hd = 340.0;
    gColorPos = ICClamp01(hd / 340.0);
    gBriPos = ICClamp01((1.0 - s) / 0.9);
}

@interface ICPanelView : UIView <UIColorPickerViewControllerDelegate>
- (void)syncUI;
- (CGFloat)desiredHeight;
- (void)placeInSuperview;
@end

@implementation ICPanelView {
    UIVisualEffectView *_blur;
    UIButton *_sun, *_eye;
    UISegmentedControl *_seg;
    NSArray<ICPreviewView *> *_tiles;
    NSArray<UILabel *> *_captions;
    ICSliderRow *_colorRow, *_briRow;
}

static const int kTileModes[4] = {ICModeDefault, ICModeDark, ICModeAuto, ICModeTinted};

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.backgroundColor = [UIColor clearColor];

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _blur.layer.cornerRadius = 28;
    _blur.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _blur.clipsToBounds = YES;
    [self addSubview:_blur];
    UIView *cv = _blur.contentView;

    _sun = [UIButton buttonWithType:UIButtonTypeSystem];
    _sun.tintColor = [UIColor labelColor];
    [_sun addTarget:self action:@selector(sunTapped) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:_sun];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"Small", @"Large"]];
    [_seg addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];
    [cv addSubview:_seg];

    _eye = [UIButton buttonWithType:UIButtonTypeSystem];
    _eye.tintColor = [UIColor secondaryLabelColor];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    UIImage *eyeImg = [UIImage systemImageNamed:@"eyedropper" withConfiguration:cfg] ?: [UIImage systemImageNamed:@"paintpalette" withConfiguration:cfg];
    [_eye setImage:eyeImg forState:UIControlStateNormal];
    [_eye addTarget:self action:@selector(eyeTapped) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:_eye];

    NSArray *names = @[@"Default", @"Dark", @"Auto", @"Tinted"];
    NSMutableArray *tiles = [NSMutableArray array], *caps = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        ICPreviewView *p = [[ICPreviewView alloc] initWithFrame:CGRectMake(0, 0, IC_TILE, IC_TILE)];
        p.mode = kTileModes[i];
        p.tag = kTileModes[i];
        p.userInteractionEnabled = YES;
        [p addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tileTapped:)]];
        [cv addSubview:p];
        [tiles addObject:p];

        UILabel *l = [UILabel new];
        l.text = names[i];
        l.font = [UIFont systemFontOfSize:12];
        l.textAlignment = NSTextAlignmentCenter;
        [cv addSubview:l];
        [caps addObject:l];
    }
    _tiles = tiles;
    _captions = caps;

    _colorRow = [[ICSliderRow alloc] initWithFrame:CGRectZero];
    _briRow   = [[ICSliderRow alloc] initWithFrame:CGRectZero];
    [_colorRow.slider addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
    [_briRow.slider   addTarget:self action:@selector(briChanged:)   forControlEvents:UIControlEventValueChanged];
    for (UISlider *s in @[_colorRow.slider, _briRow.slider]) {
        [s addTarget:self action:@selector(sliderDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    }
    [cv addSubview:_colorRow];
    [cv addSubview:_briRow];

    // радуга красный -> розовый
    NSMutableArray *cols = [NSMutableArray array], *locs = [NSMutableArray array];
    for (int i = 0; i <= 24; i++) {
        double p = i / 24.0, h, s;
        ICColorFromPos(p, &h, &s);
        [cols addObject:(id)ICUIColor(ICHSV(h, 0.95, 1.0)).CGColor];
        [locs addObject:@(p)];
    }
    _colorRow.gradient.colors = cols;
    _colorRow.gradient.locations = locs;

    [self syncUI];
    return self;
}

- (CGFloat)desiredHeight { return gMode == ICModeTinted ? 268.0 : 172.0; }

- (void)placeInSuperview {
    CGRect b = self.superview.bounds;
    CGFloat h = [self desiredHeight];
    self.frame = CGRectMake(0, b.size.height - h, b.size.width, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _blur.frame = self.bounds;
    _sun.frame = CGRectMake(14, 12, 40, 34);
    _seg.frame = CGRectMake(w / 2 - 85, 13, 170, 32);
    _eye.frame = CGRectMake(w - 14 - 40, 12, 40, 34);
    for (int i = 0; i < 4; i++) {
        CGFloat cx = w * (2 * i + 1) / 8.0;
        _tiles[i].frame = CGRectMake(cx - IC_TILE / 2, 62, IC_TILE, IC_TILE);
        _captions[i].frame = CGRectMake(cx - 40, 62 + IC_TILE + 6, 80, 16);
    }
    _colorRow.frame = CGRectMake(18, 162, w - 36, 34);
    _briRow.frame   = CGRectMake(18, 206, w - 36, 34);
}

- (void)syncUI {
    for (int i = 0; i < 4; i++) {
        _tiles[i].chosen = (gMode == kTileModes[i]);
        [_tiles[i] refresh];
        BOOL on = (gMode == kTileModes[i]);
        _captions[i].textColor = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        _captions[i].font = [UIFont systemFontOfSize:12 weight:on ? UIFontWeightSemibold : UIFontWeightRegular];
    }
    _seg.selectedSegmentIndex = gSize;

    NSString *sym = gAutoStyle == 1 ? @"sun.max.fill" : (gAutoStyle == 2 ? @"moon.fill" : @"circle.lefthalf.filled");
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    [_sun setImage:[UIImage systemImageNamed:sym withConfiguration:cfg] forState:UIControlStateNormal];
    _sun.alpha = (gMode == ICModeAuto) ? 1.0 : 0.45;

    _colorRow.slider.value = gColorPos;
    _briRow.slider.value = gBriPos;
    [self updateColors];
    BOOL tinted = (gMode == ICModeTinted);
    _colorRow.alpha = tinted ? 1 : 0;
    _briRow.alpha   = tinted ? 1 : 0;
    _colorRow.userInteractionEnabled = tinted;
    _briRow.userInteractionEnabled   = tinted;
}

- (void)updateColors {
    ICRGB lo = ICTintColor(gColorPos, 0.0), hi = ICTintColor(gColorPos, 1.0);
    _briRow.gradient.colors = @[(id)ICUIColor(lo).CGColor, (id)ICUIColor(hi).CGColor];
    double h, s;
    ICColorFromPos(gColorPos, &h, &s);
    [_colorRow setThumbColor:ICUIColor(ICHSV(h, 0.95, 1.0))];
    [_briRow setThumbColor:ICUIColor(ICTintColor(gColorPos, gBriPos))];
}

static void ICChanged(void) {
    gGen++;
    ICSyncEff();
    ICRefreshAll();
}

- (void)setModeTo:(int)m {
    if (m == gMode) return;
    gMode = m;
    ICChanged();
    ICSave();
    [UIView animateWithDuration:0.25 animations:^{
        [self syncUI];
        [self placeInSuperview];
        [self layoutIfNeeded];
    }];
}

- (void)tileTapped:(UITapGestureRecognizer *)g {
    [self setModeTo:(int)g.view.tag];
}

- (void)sunTapped {
    if (gMode != ICModeAuto) { [self setModeTo:ICModeAuto]; return; }
    gAutoStyle = (gAutoStyle + 1) % 3;     // как в системе -> светлый -> тёмный
    ICChanged();
    ICSave();
    [self syncUI];
}

- (void)sizeChanged:(UISegmentedControl *)s {
    gSize = (int)s.selectedSegmentIndex;
    [UIView animateWithDuration:0.3 animations:^{ ICRefreshAll(); }];
    ICSave();
}

- (void)colorChanged:(UISlider *)s {
    gColorPos = s.value;
    [self updateColors];
    [_tiles[3] refresh];
    ICChanged();
}

- (void)briChanged:(UISlider *)s {
    gBriPos = s.value;
    [self updateColors];
    [_tiles[3] refresh];
    ICChanged();
}

- (void)sliderDone:(UISlider *)s {
    ICSave();
}

// пипетка: системный выбор цвета, результат переводится в положения двух слайдеров
- (void)eyeTapped {
    if (gPickWin) return;
    gPickWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gPickWin.windowLevel = UIWindowLevelAlert + 300;
    gPickWin.backgroundColor = [UIColor clearColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    gPickWin.rootViewController = root;
    gPickWin.hidden = NO;

    UIColorPickerViewController *pk = [UIColorPickerViewController new];
    pk.delegate = self;
    pk.supportsAlpha = NO;
    pk.selectedColor = ICUIColor(ICTintColor(gColorPos, gBriPos));
    [root presentViewController:pk animated:YES completion:nil];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)vc didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    ICSetFromUIColor(color);
    if (gMode != ICModeTinted) gMode = ICModeTinted;
    ICChanged();
    [UIView animateWithDuration:0.2 animations:^{
        [self syncUI];
        [self placeInSuperview];
        [self layoutIfNeeded];
    }];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    ICSave();
    UIWindow *w = gPickWin;
    gPickWin = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        w.hidden = YES;
    });
}
@end

static ICPanelView *gPanelView;

// Окно на весь экран: касание вне панели закрывает её (как в iOS 18)
@interface ICPanelWindow : UIWindow <UIGestureRecognizerDelegate>
@end
@implementation ICPanelWindow
- (void)backdropTapped:(UITapGestureRecognizer *)g { ICHidePanel(); }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return !(gPanelView && [t.view isDescendantOfView:gPanelView]);
}
@end

static ICPanelWindow *gPanelWin;

static void ICShowPanel(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ICShowPanel(); });
        return;
    }
    if (gPanelWin && !gPanelWin.hidden) return;

    if (!gPanelWin) {
        gPanelWin = [[ICPanelWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gPanelWin.windowLevel = UIWindowLevelAlert + 200;
        gPanelWin.backgroundColor = [UIColor clearColor];
        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = [UIColor clearColor];
        gPanelWin.rootViewController = root;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gPanelWin action:@selector(backdropTapped:)];
        tap.delegate = gPanelWin;
        [root.view addGestureRecognizer:tap];
        gPanelView = [[ICPanelView alloc] initWithFrame:CGRectMake(0, 0, root.view.bounds.size.width, 200)];
        [root.view addSubview:gPanelView];
    }
    gPanelWin.frame = [UIScreen mainScreen].bounds;
    [gPanelWin layoutIfNeeded];
    [gPanelView syncUI];
    [gPanelView placeInSuperview];
    CGFloat h = gPanelView.bounds.size.height;
    gPanelView.transform = CGAffineTransformMakeTranslation(0, h + 20);
    gPanelWin.hidden = NO;
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:0 animations:^{ gPanelView.transform = CGAffineTransformIdentity; } completion:nil];
    NSLog(@"[Icons18] panel shown");
}

static void ICHidePanel(void) {
    ICSave();
    if (!gPanelWin || gPanelWin.hidden) return;
    CGFloat h = gPanelView.bounds.size.height;
    [UIView animateWithDuration:0.25 animations:^{ gPanelView.transform = CGAffineTransformMakeTranslation(0, h + 20); }
                     completion:^(BOOL fin) { gPanelWin.hidden = YES; gPanelView.transform = CGAffineTransformIdentity; }];
}

// =====================================================================================
#pragma mark - Вход в панель: «+» -> галерея виджетов -> Customize
// =====================================================================================

static __weak UIButton *gSheetBtn;

static UIButton *ICMakeCustomizeButton(void) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Customize" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor systemBlueColor];
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 22, 8, 22);
    b.layer.cornerRadius = 19;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 8;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    return b;
}

static void ICMaybeAddCustomize(UIViewController *vc) {
    NSString *n = NSStringFromClass([vc class]);
    if (![n containsString:@"WidgetSheet"] || ![n hasSuffix:@"ViewController"]) return;
    if ([n containsString:@"Detail"] || [n containsString:@"Configur"] || [n containsString:@"Navigation"]) return;
    UIView *host = vc.view;
    if (!host || !host.window) return;
    if (gSheetBtn && gSheetBtn.window && gSheetBtn.window == host.window) return;

    UIButton *b = ICMakeCustomizeButton();
    __weak UIViewController *wvc = vc;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        UIViewController *top = wvc;
        while (top.parentViewController) top = top.parentViewController;
        UIViewController *presenter = top.presentingViewController;
        if (presenter) {
            [presenter dismissViewControllerAnimated:YES completion:^{ ICShowPanel(); }];
        }
        // страховка, если галерея показана не через presentViewController
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ICShowPanel(); });
    }] forControlEvents:UIControlEventTouchUpInside];

    b.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [b.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-14],
    ]];
    gSheetBtn = b;
    NSLog(@"[Icons18] Customize button added to %@", n);
}

// Запасной вход: если класса галереи виджетов нет, показываем кнопку Customize в режиме редактирования
static UIWindow *gPillWin;

static void ICEditingChanged(BOOL editing) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (editing) {
            if (!gPillWin) {
                CGSize sc = ICScreenSize();
                gPillWin = [[UIWindow alloc] initWithFrame:CGRectMake((sc.width - 116) / 2, 22, 116, 38)];
                gPillWin.windowLevel = UIWindowLevelAlert + 150;
                gPillWin.backgroundColor = [UIColor clearColor];
                UIViewController *root = [UIViewController new];
                root.view.backgroundColor = [UIColor clearColor];
                gPillWin.rootViewController = root;
                UIButton *b = ICMakeCustomizeButton();
                b.frame = CGRectMake(0, 0, 116, 38);
                [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { ICShowPanel(); }]
            forControlEvents:UIControlEventTouchUpInside];
                [root.view addSubview:b];
            }
            gPillWin.hidden = NO;
        } else {
            gPillWin.hidden = YES;
        }
    });
}

static void (*ic_orig_setEditing)(id, SEL, BOOL, BOOL);
static void ic_new_setEditing(id self, SEL _cmd, BOOL editing, BOOL animated) {
    if (ic_orig_setEditing) ic_orig_setEditing(self, _cmd, editing, animated);
    ICEditingChanged(editing);
}

static BOOL ICGalleryClassExists(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    BOOL found = NO;
    int logged = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = class_getName(list[i]);
        if (strstr(nm, "WidgetSheet") && strstr(nm, "ViewController")) {
            if (logged++ < 6) NSLog(@"[Icons18] widget sheet class: %s", nm);
            if (!strstr(nm, "Detail") && !strstr(nm, "Configur") && !strstr(nm, "Navigation")) found = YES;
        }
    }
    free(list);
    return found;
}

static void ICInstallEntryPoints(void) {
    if (ICGalleryClassExists()) {
        NSLog(@"[Icons18] entry point: Customize button in the widget gallery");
        return;
    }
    Class c = NSClassFromString(@"SBIconListView");
    SEL s = NSSelectorFromString(@"setEditing:animated:");
    if (c && [c instancesRespondToSelector:s]) {
        MSHookMessageEx(c, s, (IMP)ic_new_setEditing, (IMP *)&ic_orig_setEditing);
        NSLog(@"[Icons18] entry point: fallback Customize button in edit mode");
    } else {
        NSLog(@"[Icons18] ERROR: no entry point found (no widget sheet class, no SBIconListView setEditing:animated:)");
    }
}

// =====================================================================================
#pragma mark - Хуки
// =====================================================================================

%group SpringBoardHooks

%hook SBIconImageView
- (void)layoutSubviews {
    %orig;
    [gIconViews addObject:self];
    ICApplyIcon(self, NO);
}
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    %orig;
    if (ICSyncEff()) ICRefreshAll();     // Auto: система переключилась между светлой и тёмной темой
}
%end

%hook SBIconView
- (void)layoutSubviews {
    %orig;
    [gIconCells addObject:self];
    ICApplySize(self);
    if (ICIconIsWidget(ICMsg0(self, @"icon"))) {
        UIView *content = ICWidgetContentOf(self);
        if (content) {
            [gWidgetViews addObject:content];
            ICApplyWidgetContent(content);
        }
    }
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ICMaybeAddCustomize(self);
}
%end

%end // SpringBoardHooks

%group SettingsHooks

%hook PSTableCell
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    %orig;
    if (ICSyncEff()) ICRefreshAll();
}
- (void)layoutSubviews {
    %orig;
    UIImageView *iv = self.imageView;
    if (iv) {
        [gSettingsViews addObject:iv];
        ICApplySettings(iv);
    }
}
%end

%end // SettingsHooks

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    gSrcCache      = [NSMutableDictionary dictionary];
    gDynamicIdents = [NSSet setWithObjects:@"com.apple.mobiletimer", @"com.apple.mobilecal", nil];
    gIconViews     = [NSHashTable weakObjectsHashTable];
    gIconCells     = [NSHashTable weakObjectsHashTable];
    gDynViews      = [NSHashTable weakObjectsHashTable];
    gWidgetViews   = [NSHashTable weakObjectsHashTable];
    gSettingsViews = [NSHashTable weakObjectsHashTable];
    ICLoad();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    ICPrefsChanged, IC_NOTIFY, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    if ([bid isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardHooks);
        ICInstallEntryPoints();
    } else if ([bid isEqualToString:@"com.apple.Preferences"]) {
        %init(SettingsHooks);
    }
}
