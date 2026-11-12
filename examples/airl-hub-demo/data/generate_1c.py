#!/usr/bin/env python3
"""Генератор СИНТЕТИЧЕСКИХ данных для демо-хаба AIRL.

Форма — как у выгрузок 1С:Бухгалтерия для Казахстана (2 информационные базы:
ТОО «AIRL» и ТОО «AIRL Dev»), банковских выписок двух банков, amoCRM и Google
Таблицы учёта потоков курса. Ни одного настоящего человека или компании:

* названия компаний — «ТОО «Демо-…»», имена — случайные сочетания частых имён
  с инициалом фамилии;
* телефоны — только диапазон +7 700 000 xx xx;
* БИН начинается с «9914», ИИН — с «9913» (месяц 13/14 не существует —
  такие номера не проходят ни один настоящий реестр);
* банки — вымышленные «Демо Банк Алатау» и «Демо Банк Степь».

Детерминированно: один и тот же seed и одна и та же дата «сегодня» дают
одинаковые файлы. Дата «сегодня» — текущая (часовой пояс Asia/Almaty) или
переменная DEMO_TODAY=ГГГГ-ММ-ДД. История — 18 месяцев, включая текущий.

Запуск:  python3 data/generate_1c.py --out data/out
"""
import argparse
import csv
import os
import random
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

ALMATY = timezone(timedelta(hours=5))
SEASON = {1: 0.75, 2: 0.95, 3: 1.05, 4: 1.05, 5: 0.95, 6: 0.85,
          7: 0.65, 8: 0.70, 9: 1.10, 10: 1.20, 11: 1.25, 12: 1.15}
VAT = Decimal("0.12")

FIRST = ["Айгерим", "Алия", "Дана", "Асель", "Мадина", "Камила", "Жанна", "Сабина", "Томирис",
         "Арман", "Ерлан", "Тимур", "Нурлан", "Данияр", "Руслан", "Айдос", "Бауыржан", "Санжар",
         "Ольга", "Ирина", "Елена", "Наталья", "Анна", "Дмитрий", "Сергей", "Алексей", "Максим"]
LAST_INITIAL = "АБВГДЕЖЗИКЛМНОПРСТУХШЭЮЯ"
SURNAMES = ["Демоева", "Тестова", "Примерова", "Образцова", "Шаблонова", "Макетова",
            "Демоев", "Тестов", "Примеров", "Образцов", "Шаблонов", "Макетов"]
COMPANY_WORDS = ["Ритейл", "Логистик", "Агро", "Медиа", "Строй", "Финанс", "Фуд", "Тех",
                 "Энерго", "Фарм", "Транс", "Девелопмент", "Сервис", "Трейд", "Консалт"]
CHANNELS = [("instagram", 0.30), ("site", 0.25), ("telegram", 0.15), ("referral", 0.12),
            ("meta_form", 0.13), ("event", 0.05)]
SOURCES = ["hh.kz", "Telegram-каналы", "Рекомендация", "LinkedIn", "Карьерный сайт AIRL"]
# Доля рекламного бюджета по каналам (amoCRM utm_source): site — поиск Google и сайт
MKT_SHARES = [("instagram", 0.34), ("site", 0.24), ("telegram", 0.12), ("meta_form", 0.18),
              ("event", 0.08), ("referral", 0.04)]
CABINET = {"instagram": "Meta Ads", "meta_form": "Meta Ads", "site": "Google Ads", "telegram": "Telegram Ads",
           "event": "Таблица бюджета", "referral": "Таблица бюджета"}
LOSS = ["Дорого", "Не устроили даты потока", "Не отвечает", "Выбрал другую школу",
        "Отложил на следующий год", "Нужна рассрочка дольше"]


def campaign_title(nm, ch):
    kind = {"ig_vibeops": "Instagram · курс VibeOps", "ig_corp_ai": "Instagram · обучение команд",
            "google_search": "Google · поиск «курс ИИ»", "tg_channels": "Telegram · посевы в каналах",
            "meta_leadform": "Meta · лид-форма курса", "event_meetup": "Митап AIRL",
            "referral_program": "Реферальная программа"}
    base = nm.rsplit("_", 1)[0] if nm != "referral_program" else nm
    ym = nm.rsplit("_", 1)[1] if nm != "referral_program" else ""
    return kind.get(base, nm) + (f" · {ym[2:]}.20{ym[:2]}" if ym else "")


def money(x):
    return Decimal(x).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def month_start(d):
    return d.replace(day=1)


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    return date(d.year + y, m + 1, 1)


def month_end(d):
    return add_months(month_start(d), 1) - timedelta(days=1)


class Gen:
    def __init__(self, today, seed):
        self.today = today
        self.rnd = random.Random(seed)
        self.start = add_months(month_start(today), -17)
        self.rows = {k: [] for k in [
            "organizations", "kontragenty", "dogovory", "nomenklatura", "realizatsiya",
            "realizatsiya_tovary", "postuplenie_rs", "pko", "spisanie_rs", "zatraty",
            "bank_accounts", "ostatki_dc", "sotrudniki", "statement_lines", "leads",
            "amo_users", "cohorts", "cohort_students",
            # HR: 1С:ЗУП (начисления, отсутствия) и таблица вакансий HR
            "zup_nachisleniya", "zup_otsutstviya", "vacancies",
            # Маркетинг: рекламные кабинеты и таблица бюджета маркетинга
            "ad_campaigns", "ad_spend", "mkt_budget"]}
        # Отдельные генераторы для HR и маркетинга: основной поток случайных чисел не сдвигается,
        # поэтому деньги, заявки и потоки остаются теми же, что и до появления этих отделов.
        self.hr_rnd = random.Random(seed * 7 + 3)
        self.mkt_rnd = random.Random(seed * 11 + 5)
        self.campaigns = {}     # (channel, ГГГГ-ММ) -> [utm_campaign]
        self.campaign_seen = set()
        self.seq = {}
        self.phones_used = set()
        self.kontr = {}         # (infobase, key) -> ref

    # ---------- служебное ----------
    def next_no(self, prefix, width=6):
        self.seq[prefix] = self.seq.get(prefix, 0) + 1
        return f"{prefix}-{self.seq[prefix]:0{width}d}"

    def factor(self, d):
        months = (d.year - self.start.year) * 12 + d.month - self.start.month
        return SEASON[d.month] * (1.025 ** months)

    def phone(self):
        for _ in range(200):
            p = f"+7700000{self.rnd.randint(0, 9999):04d}"
            if p not in self.phones_used:
                self.phones_used.add(p)
                return p
        return f"+7700000{self.rnd.randint(0, 9999):04d}"

    def person_name(self):
        return f"{self.rnd.choice(FIRST)} {self.rnd.choice(LAST_INITIAL)}."

    def days(self, a, b):
        d = a
        while d <= b:
            yield d
            d += timedelta(days=1)

    # ---------- справочники ----------
    def setup(self):
        r = self.rows
        r["organizations"] += [
            dict(infobase="airl", org_ref="ORG-AIRL", name="ТОО «AI Research Labs» (демо-копия)", bin="991400000001"),
            dict(infobase="airl_dev", org_ref="ORG-DEV", name="ТОО «AIRL Dev» (демо-копия)", bin="991400000002"),
        ]
        r["bank_accounts"] += [
            dict(infobase="airl", ref="BA-AIRL-1", name="Основной счёт", bank_name="Демо Банк Алатау",
                 iban="KZ00DEMO0000000000001", currency="KZT", kind="bank"),
            dict(infobase="airl", ref="BA-AIRL-2", name="Счёт для эквайринга", bank_name="Демо Банк Степь",
                 iban="KZ00DEMO0000000000002", currency="KZT", kind="bank"),
            dict(infobase="airl", ref="KASSA-AIRL", name="Касса офиса", bank_name="",
                 iban="", currency="KZT", kind="kassa"),
            dict(infobase="airl_dev", ref="BA-DEV-1", name="Основной счёт", bank_name="Демо Банк Алатау",
                 iban="KZ00DEMO0000000000003", currency="KZT", kind="bank"),
        ]
        for acc, amt in [("BA-AIRL-1", 28_000_000), ("BA-AIRL-2", 3_000_000),
                         ("KASSA-AIRL", 300_000), ("BA-DEV-1", 14_000_000)]:
            ib = "airl_dev" if acc == "BA-DEV-1" else "airl"
            r["ostatki_dc"].append(dict(infobase=ib, account_ref=acc, date=self.start.isoformat(), sum=money(amt)))
        for ib in ("airl", "airl_dev"):
            for code, name, group in [
                ("00001", "Курс VibeOps (место в потоке)", "Курс VibeOps"),
                ("00002", "Корпоративное обучение ИИ", "Корпоративное обучение"),
                ("00003", "Разработка и внедрение ИИ-решения", "Разработка ИИ"),
                ("00004", "Консалтинг по ИИ (абонемент)", "Консалтинг"),
                ("00005", "Субподряд: разработка учебных ИИ-ассистентов", "Разработка ИИ"),
            ]:
                r["nomenklatura"].append(dict(infobase=ib, ref=f"NOM-{ib}-{code}", code=code, name=name,
                                              group_name=group, vat_rate="12"))
        # Своё юрлицо как контрагент в чужой базе (внутригрупповые обороты)
        self.add_company("airl", "GRP-DEV", "ТОО «AIRL Dev» (демо-копия)", "991400000002", is_group=True)
        self.add_company("airl_dev", "GRP-AIRL", "ТОО «AI Research Labs» (демо-копия)", "991400000001", is_group=True)
        # Поставщики
        self.suppliers = {}
        for key, name in [("landlord", "ТОО «Демо-Бизнес-Центр»"), ("ads", "ТОО «Демо-Реклама»"),
                          ("cloud", "ТОО «Демо-Облако KZ»"), ("aiapi", "Демо AI API Ltd"),
                          ("freelance", "ИП «Подрядчик Демо»"), ("budget", "Бюджет РК (налоги, демо)"),
                          ("owner", "Участник ТОО (демо)"),
                          ("bank", "Демо Банк Алатау")]:
            bin_ = f"9914{self.rnd.randint(10_000_000, 99_999_999)}"
            for ib in ("airl", "airl_dev"):
                self.add_company(ib, f"SUP-{key}", name, bin_)
            self.suppliers[key] = bin_
        # Клиенты B2B
        self.companies = []
        used = set()
        for i in range(70):
            while True:
                nm = f"ТОО «Демо-{self.rnd.choice(COMPANY_WORDS)} {self.rnd.randint(1, 99):02d}»"
                if nm not in used:
                    used.add(nm)
                    break
            bin_ = f"9914{self.rnd.randint(10_000_000, 99_999_999)}"
            c = dict(key=f"B2B-{i + 1:03d}", name=nm, bin=bin_, phone=self.phone(),
                     email=f"office{i + 1:03d}@demo-client.kz",
                     reliability=self.rnd.choices(["good", "slow", "bad"], [0.78, 0.18, 0.04])[0])
            self.companies.append(c)
        # Сотрудники
        staff = ([("Руководство", "Генеральный директор")] + [("Руководство", "Операционный директор")] +
                 [("Финансы", "Финансовый директор"), ("Финансы", "Главный бухгалтер"), ("Финансы", "Бухгалтер")] +
                 [("Продажи", "Руководитель продаж")] + [("Продажи", "Менеджер по продажам")] * 4 +
                 [("Обучение", "Руководитель обучения")] + [("Обучение", "Куратор потока")] * 3 +
                 [("Обучение", "Преподаватель")] * 3 +
                 [("Разработка", "Технический директор")] + [("Разработка", "Инженер ИИ")] * 6 +
                 [("Разработка", "Аналитик данных")])
        salary = {"Генеральный директор": 1_800_000, "Операционный директор": 1_300_000,
                  "Финансовый директор": 1_200_000, "Главный бухгалтер": 750_000, "Бухгалтер": 450_000,
                  "Руководитель продаж": 900_000, "Менеджер по продажам": 420_000,
                  "Руководитель обучения": 950_000, "Куратор потока": 380_000, "Преподаватель": 650_000,
                  "Технический директор": 1_600_000, "Инженер ИИ": 1_050_000, "Аналитик данных": 800_000}
        self.employees = []
        for i, (dept, pos) in enumerate(staff):
            ib = "airl_dev" if dept == "Разработка" else "airl"
            hire = self.start - timedelta(days=self.rnd.randint(60, 900))
            if i >= 20:  # часть команды пришла в течение периода
                hire = self.start + timedelta(days=self.rnd.randint(30, 450))
            fire = ""
            if i in (8, 17):  # двое ушли
                fire = (self.start + timedelta(days=self.rnd.randint(200, 400))).isoformat()
            fio = f"{self.rnd.choice(SURNAMES)} {self.rnd.choice(FIRST)}"
            e = dict(infobase=ib, ref=f"EMP-{i + 1:03d}", tab_no=f"{i + 1:04d}", fio=fio,
                     podrazdelenie=dept, dolzhnost=pos, hire_date=hire.isoformat(), fire_date=fire,
                     oklad=salary[pos])
            self.rows["sotrudniki"].append(e)
            self.employees.append(e)
        self.setup_hr(salary)
        # Менеджеры amoCRM
        self.managers = []
        for i in range(5):
            u = dict(id=str(9001 + i), name=f"{self.rnd.choice(FIRST)} {self.rnd.choice(LAST_INITIAL)}. (менеджер)")
            self.rows["amo_users"].append(u)
            self.managers.append(u["id"])

    def add_company(self, ib, key, name, bin_, is_group=False, phone="", email=""):
        ref = f"K-{ib}-{key}"
        self.rows["kontragenty"].append(dict(
            infobase=ib, ref=ref, code=key, name=name, kind="ЮрЛицо", bin_iin=bin_, phone=phone,
            email=email, is_group="true" if is_group else "false", deletion_mark="false"))
        self.kontr[(ib, key)] = ref
        return ref

    def company_ref(self, ib, c):
        k = (ib, c["key"])
        if k not in self.kontr:
            self.add_company(ib, c["key"], c["name"], c["bin"], phone=c["phone"], email=c["email"])
        return self.kontr[k]

    def add_person(self, phone, name):
        key = f"FL-{len([1 for k in self.kontr if k[1].startswith('FL-')]) + 1:05d}"
        iin = f"9913{self.rnd.randint(10_000_000, 99_999_999)}"
        ref = f"K-airl-{key}"
        self.rows["kontragenty"].append(dict(
            infobase="airl", ref=ref, code=key, name=name, kind="ФизЛицо", bin_iin=iin, phone=phone,
            email=f"student{key[3:]}@demo-mail.kz", is_group="false", deletion_mark="false"))
        self.kontr[("airl", key)] = ref
        return ref

    def contract(self, ib, kref, terms, kind="СПокупателем"):
        ref = f"DOG-{ib}-{len(self.rows['dogovory']) + 1:05d}"
        self.rows["dogovory"].append(dict(infobase=ib, ref=ref, number=self.next_no(f"Д{ib[:1].upper()}", 4),
                                          date=self.start.isoformat(), kontragent_ref=kref, kind=kind,
                                          payment_terms_days=terms, currency="KZT"))
        return ref

    # ---------- документы ----------
    def sale(self, ib, d, kref, dog, nom_code, gross, due, manager, qty=1, cohort=""):
        gross = money(gross)
        vat = money(gross * VAT / (1 + VAT))
        ref = f"RU-{ib}-{len(self.rows['realizatsiya']) + 1:06d}"
        number = self.next_no("РУ" if ib == "airl" else "РД")
        self.rows["realizatsiya"].append(dict(
            infobase=ib, ref=ref, number=number, date=d.isoformat(), kontragent_ref=kref, dogovor_ref=dog,
            posted="true", deletion_mark="false", sum_total=gross, sum_vat=vat, currency="KZT",
            due_date=due.isoformat(), manager_code=manager))
        self.rows["realizatsiya_tovary"].append(dict(
            infobase=ib, doc_ref=ref, line_no=1, nomenklatura_ref=f"NOM-{ib}-{nom_code}", qty=qty,
            price=money(gross / qty), sum=gross, sum_vat=vat, cohort_code=cohort))
        return dict(ref=ref, number=number, gross=gross, ib=ib, date=d, kref=kref, dog=dog)

    def bank_line(self, ib, acc, d, amount, cp_name, cp_bin, purpose, doc_no):
        bank = "Демо Банк Степь" if acc == "BA-AIRL-2" else "Демо Банк Алатау"
        iban = {"BA-AIRL-1": "KZ00DEMO0000000000001", "BA-AIRL-2": "KZ00DEMO0000000000002",
                "BA-DEV-1": "KZ00DEMO0000000000003"}[acc]
        line_id = f"{iban[-4:]}-{d.strftime('%Y%m%d')}-{len(self.rows['statement_lines']) + 1:06d}"
        self.rows["statement_lines"].append(dict(
            bank=bank, account_iban=iban, statement_id=f"{iban[-4:]}-{d.strftime('%Y%m%d')}",
            line_id=line_id, value_date=d.isoformat(), amount=money(amount), currency="KZT",
            counterparty_name=cp_name, counterparty_bin=cp_bin, purpose=purpose, doc_no=doc_no))
        return line_id

    def receipt(self, sale, d, amount, channel="bank", book=True, kname="", kbin=""):
        """Оплата покупателя. channel: bank (основной), acq (эквайринг), cash (касса).
        book=False — деньги пришли в банк, но в 1С ещё не разнесены."""
        if d >= self.today:
            return
        amount = money(amount)
        ib = sale["ib"]
        if channel == "cash":
            self.rows["pko"].append(dict(
                infobase=ib, ref=f"PKO-{len(self.rows['pko']) + 1:06d}", number=self.next_no("ПКО"),
                date=d.isoformat(), kontragent_ref=sale["kref"], osnovanie_ref=sale["ref"], sum=amount,
                kassa_ref="KASSA-AIRL", cf_article="Поступления от покупателей", posted="true",
                deletion_mark="false"))
            return
        acc = {"airl_dev": "BA-DEV-1"}.get(ib, "BA-AIRL-2" if channel == "acq" else "BA-AIRL-1")
        doc_no = f"{self.rnd.randint(100, 9999)}"
        purpose = f"Оплата по акту {sale['number']} от {sale['date'].strftime('%d.%m.%Y')}, в т.ч. НДС 12%"
        line = self.bank_line(ib, acc, d, amount, kname, kbin, purpose, doc_no)
        if book:
            self.rows["postuplenie_rs"].append(dict(
                infobase=ib, ref=f"PRS-{len(self.rows['postuplenie_rs']) + 1:06d}", number=self.next_no("ПРС"),
                date=d.isoformat(), kontragent_ref=sale["kref"], dogovor_ref=sale["dog"],
                osnovanie_ref=sale["ref"], sum=amount, bank_account_ref=acc,
                cf_article="Поступления от покупателей", posted="true", deletion_mark="false",
                bank_line_id=line))

    def expense(self, ib, d, sup_key, account, statya, net, doc_type="ПоступлениеУслуг", vat=True,
                pay_after=None, cf_article=None, acc=None):
        if d >= self.today:
            return
        net = money(net)
        gross = money(net * (1 + VAT)) if vat else net
        kref = self.kontr.get((ib, sup_key), "")
        self.rows["zatraty"].append(dict(
            infobase=ib, ref=f"ZT-{len(self.rows['zatraty']) + 1:06d}", doc_type=doc_type,
            number=self.next_no("ЗТ"), date=d.isoformat(), kontragent_ref=kref, account_code=account,
            statya_zatrat=statya, sum=net, sum_vat=money(gross - net), posted="true", deletion_mark="false"))
        if pay_after is not None:
            self.payment_out(ib, d + timedelta(days=pay_after), sup_key, gross, cf_article or statya, acc)

    def payment_out(self, ib, d, sup_key, amount, cf_article, acc=None):
        if d >= self.today:
            return
        acc = acc or ("BA-DEV-1" if ib == "airl_dev" else "BA-AIRL-1")
        kref = self.kontr.get((ib, sup_key), "")
        name = next((k["name"] for k in self.rows["kontragenty"] if k["ref"] == kref), "")
        bin_ = next((k["bin_iin"] for k in self.rows["kontragenty"] if k["ref"] == kref), "")
        line = self.bank_line(ib, acc, d, -money(amount), name, bin_, f"Оплата: {cf_article}", f"{self.rnd.randint(100, 9999)}")
        self.rows["spisanie_rs"].append(dict(
            infobase=ib, ref=f"SRS-{len(self.rows['spisanie_rs']) + 1:06d}", number=self.next_no("СРС"),
            date=d.isoformat(), kontragent_ref=kref, sum=money(amount), bank_account_ref=acc,
            cf_article=cf_article, posted="true", deletion_mark="false", bank_line_id=line))

    def pay_delay(self, reliability, doc_date=None):
        """Задержка оплаты после срока, дней. None — не платит (только свежие долги:
        старые безнадёжные долги в 1С уже оплачены поздно или списаны)."""
        x = self.rnd.random()
        if reliability == "good":
            return self.rnd.randint(-7, 5) if x < 0.95 else self.rnd.randint(10, 35)
        if reliability == "slow":
            return self.rnd.randint(0, 25) if x < 0.85 else self.rnd.randint(30, 70)
        recent = doc_date is not None and doc_date > self.today - timedelta(days=150)
        if recent and x < 0.5:
            return None
        return self.rnd.randint(40, 120)

    # ---------- лиды ----------
    def lead(self, created, phone, name, won=False, price=0, company_bin="", closed=None, channel=None):
        ch = channel or self.rnd.choices([c for c, _ in CHANNELS], [w for _, w in CHANNELS])[0]
        campaign = self.campaign_for(ch, created)
        if won:
            status = "Успешно реализовано"
        elif created > self.today - timedelta(days=21) and self.rnd.random() < 0.55:
            status = self.rnd.choice(["Первичный контакт", "Переговоры", "Принимают решение"])
        else:
            status = "Закрыто и не реализовано"
        closed_at = ""
        loss = ""
        if status == "Успешно реализовано":
            closed_at = (closed or created).isoformat()
        elif status == "Закрыто и не реализовано":
            closed_at = (created + timedelta(days=self.rnd.randint(1, 20))).isoformat()
            loss = self.rnd.choice(LOSS)
        ts = datetime(created.year, created.month, created.day, self.rnd.randint(8, 22),
                      self.rnd.randint(0, 59), tzinfo=ALMATY)
        self.rows["leads"].append(dict(
            id=str(30_000_000 + len(self.rows["leads"]) + 1), name=f"Заявка: {name}", created_at=ts.isoformat(),
            pipeline="B2B" if company_bin else "Курс VibeOps", status=status, price=money(price),
            responsible_user_id=self.rnd.choice(self.managers), contact_name=name, contact_phone=phone,
            company_bin=company_bin, utm_source=ch, utm_campaign=campaign, closed_at=closed_at, loss_reason=loss))

    # ---------- сценарий ----------
    def run(self):
        self.setup()
        T = self.today
        # Потоки курса VibeOps: старт примерно раз в 5 недель
        cohort_starts = []
        d = self.start + timedelta(days=10)
        while d < T + timedelta(days=70):
            cohort_starts.append(d)
            d += timedelta(days=35 + self.rnd.randint(-3, 3))
        for n, start in enumerate(cohort_starts, 1):
            code = f"VO-{start.strftime('%y%m')}-{n:02d}"
            fmt = "офлайн, Алматы" if n % 3 == 0 else "онлайн"
            cap = 40 if fmt == "онлайн" else 30
            end = start + timedelta(days=42)
            self.rows["cohorts"].append(dict(cohort_code=code, course="VibeOps", start_date=start.isoformat(),
                                             end_date=end.isoformat(), capacity=cap, format=fmt,
                                             curator=f"Куратор {(n % 3) + 1}"))
            fill = min(1.0, 0.55 + 0.35 * self.factor(start) / 1.6 + self.rnd.uniform(-0.1, 0.1))
            if start > T + timedelta(days=30):
                fill *= 0.35  # продажи будущего потока только начались
            elif start > T:
                fill *= 0.75
            seats = int(cap * fill)
            for s in range(seats):
                sold = start - timedelta(days=self.rnd.randint(2, 32))
                if sold >= T or sold < self.start:
                    continue
                price = 390_000 if fmt == "онлайн" else 490_000
                if self.rnd.random() < 0.18:
                    price = int(price * 0.85)  # ранняя запись
                phone = self.phone()
                name = self.person_name()
                kref = self.add_person(phone, name)
                dog = self.contract("airl", kref, 0)
                self.lead(sold - timedelta(days=self.rnd.randint(1, 14)), phone, name, won=True, price=price,
                          closed=sold)
                installment = self.rnd.random() < 0.16
                if installment:
                    sale = self.sale("airl", sold, kref, dog, "00001", price, start, "9001", cohort=code)
                    self.receipt(sale, sold, price / 2, channel="acq", kname=name, kbin="")
                    late = self.rnd.choices([0, 10, 45, None], [0.6, 0.2, 0.1, 0.1])[0]
                    if late is not None:
                        self.receipt(sale, start + timedelta(days=late), price / 2, channel="acq", kname=name)
                else:
                    sale = self.sale("airl", sold, kref, dog, "00001", price, sold, "9002", cohort=code)
                    ch = self.rnd.choices(["acq", "bank", "cash"], [0.7, 0.2, 0.1])[0]
                    self.receipt(sale, sold, price, channel=ch, kname=name)
                # Прогресс слушателя
                if end < T:
                    st = self.rnd.choices(["завершил", "отчислен"], [0.82, 0.18])[0]
                elif start <= T:
                    st = "учится"
                else:
                    st = "записан"
                self.rows["cohort_students"].append(dict(
                    cohort_code=code, kontragent_ref=kref, seat_no=s + 1, status=st,
                    attended_pct=self.rnd.randint(70, 100) if st == "завершил" else (
                        self.rnd.randint(10, 60) if st == "отчислен" else self.rnd.randint(40, 100) if st == "учится" else 0),
                    final_project="да" if st == "завершил" and self.rnd.random() < 0.8 else "нет"))
        # Корпоративные места на потоках (компания платит за сотрудников)
        for start in cohort_starts:
            if start >= T:
                continue
            for _ in range(self.rnd.randint(0, 2)):
                c = self.rnd.choice(self.companies)
                kref = self.company_ref("airl", c)
                dog = self.contract("airl", kref, 15)
                qty = self.rnd.randint(2, 5)
                sold = start - timedelta(days=self.rnd.randint(5, 20))
                if sold < self.start:
                    continue
                sale = self.sale("airl", sold, kref, dog, "00001", 390_000 * qty, sold + timedelta(days=15), "9003",
                                 qty=qty, cohort=self.rows["cohorts"][cohort_starts.index(start)]["cohort_code"])
                delay = self.pay_delay(c["reliability"], sold)
                if delay is not None:
                    self.receipt(sale, sold + timedelta(days=15 + delay), sale["gross"], kname=c["name"], kbin=c["bin"])
                self.lead(sold - timedelta(days=12), c["phone"], c["name"], won=True, price=sale["gross"],
                          company_bin=c["bin"], closed=sold)

        # Корпоративное обучение, разработка, консалтинг — по месяцам
        m = self.start
        retainers = self.rnd.sample(self.companies, 7)
        while m <= T:
            f = self.factor(m)
            last = min(month_end(m), T - timedelta(days=1))
            # Корпоративное обучение (AIRL)
            for _ in range(max(1, int(round(4 * f + self.rnd.uniform(-1, 1))))):
                c = self.rnd.choice(self.companies)
                d = m + timedelta(days=self.rnd.randint(0, (last - m).days))
                if d >= T:
                    continue
                kref = self.company_ref("airl", c)
                dog = self.contract("airl", kref, 30)
                amt = self.rnd.choice([1_500_000, 2_200_000, 2_800_000, 3_600_000, 4_500_000, 6_000_000])
                sale = self.sale("airl", d, kref, dog, "00002", amt, d + timedelta(days=30), self.rnd.choice(self.managers))
                self.lead(d - timedelta(days=self.rnd.randint(10, 40)), c["phone"], c["name"], won=True,
                          price=amt, company_bin=c["bin"], closed=d)
                delay = self.pay_delay(c["reliability"], d)
                if delay is not None:
                    pay = d + timedelta(days=30 + delay)
                    book = pay < T - timedelta(days=9) or self.rnd.random() < 0.3
                    self.receipt(sale, pay, sale["gross"], book=book, kname=c["name"], kbin=c["bin"])
            # Разработка и внедрение ИИ (AIRL Dev): этапы проектов
            for _ in range(max(1, int(round(2.2 * f + self.rnd.uniform(-1, 1))))):
                c = self.rnd.choice(self.companies)
                d = m + timedelta(days=self.rnd.randint(0, (last - m).days))
                if d >= T:
                    continue
                kref = self.company_ref("airl_dev", c)
                dog = self.contract("airl_dev", kref, 30)
                amt = self.rnd.choice([3_500_000, 4_800_000, 6_500_000, 8_000_000, 12_000_000])
                sale = self.sale("airl_dev", d, kref, dog, "00003", amt, d + timedelta(days=30), self.rnd.choice(self.managers))
                self.lead(d - timedelta(days=self.rnd.randint(20, 60)), c["phone"], c["name"], won=True,
                          price=amt, company_bin=c["bin"], closed=d)
                delay = self.pay_delay(c["reliability"], d)
                if delay is not None:
                    pay = d + timedelta(days=30 + delay)
                    book = pay < T - timedelta(days=9) or self.rnd.random() < 0.3
                    self.receipt(sale, pay, sale["gross"], book=book, kname=c["name"], kbin=c["bin"])
                # внешние подрядчики — 40 % этапа
                self.expense("airl_dev", d + timedelta(days=3), "SUP-freelance", "7010.01", "Подрядчики",
                             amt / 1.12 * 0.40, pay_after=12, cf_article="Оплата поставщикам")
            # Консалтинг-абонементы (AIRL)
            for c in retainers:
                d = m + timedelta(days=24 if m.month != 2 else 22)
                if d >= T:
                    continue
                kref = self.company_ref("airl", c)
                dog = self.contract("airl", kref, 10)
                amt = 900_000 if c["key"] < "B2B-030" else 1_600_000
                sale = self.sale("airl", d, kref, dog, "00004", amt, d + timedelta(days=10), "9004")
                delay = self.pay_delay(c["reliability"], d)
                if delay is not None:
                    pay = d + timedelta(days=10 + delay)
                    book = pay < T - timedelta(days=9) or self.rnd.random() < 0.3
                    self.receipt(sale, pay, sale["gross"], book=book, kname=c["name"], kbin=c["bin"])
            # Внутригрупповой субподряд: AIRL Dev → AIRL (учебные ИИ-ассистенты)
            d = m + timedelta(days=26 if m.month != 2 else 25)
            if d < T:
                amt = round(1_400_000 * f, -3)
                grp = {"ref": "", "kref": self.kontr[("airl_dev", "GRP-AIRL")]}
                dog = self.contract("airl_dev", grp["kref"], 15)
                sale = self.sale("airl_dev", d, grp["kref"], dog, "00005", amt, d + timedelta(days=15), "9005")
                self.expense("airl", d, "GRP-DEV", "7010.01", "Подрядчики", amt / 1.12)
                pay = d + timedelta(days=14)
                if pay < T:
                    self.payment_out("airl", pay, "GRP-DEV", sale["gross"], "Оплата поставщикам")
                    self.receipt(sale, pay, sale["gross"], kname="ТОО «AI Research Labs» (демо-копия)", kbin="991400000001")
            # Расходы месяца
            me = month_end(m)
            # ФОТ: расчёт 1С:ЗУП по сотрудникам (текущий месяц — плановое начисление «предварительно»),
            # в 1С:Бухгалтерию — одной проводкой в конце закрытого месяца, выплата 5-го следующего.
            for ib in ("airl", "airl_dev"):
                fot = self.payroll_month(ib, m, me, final=me < T)
                if me < T:
                    self.expense(ib, me, "SUP-budget", "7210.01", "ФОТ", fot, doc_type="НачислениеЗарплаты",
                                 vat=False, pay_after=5, cf_article="Зарплата")
                # аренда
                rent = 1_900_000 if ib == "airl" else 650_000
                self.expense(ib, m, "SUP-landlord", "7210.02", "Аренда", rent, pay_after=2, cf_article="Аренда")
                # облако и API ИИ — растёт, последние 2 месяца с перерасходом
                months = (m.year - self.start.year) * 12 + m.month - self.start.month
                cloud = (350_000 if ib == "airl" else 800_000) * (1.07 ** months)
                if m >= add_months(month_start(T), -1):
                    cloud *= 1.45
                self.expense(ib, m + timedelta(days=4), "SUP-aiapi" if ib == "airl_dev" else "SUP-cloud",
                             "7010.02", "Облако и API ИИ", cloud, pay_after=3, cf_article="Оплата поставщикам")
                # налог на прибыль (начисление ежемесячно, оплата 25-го следующего)
                if me < T:
                    self.expense(ib, me, "SUP-budget", "7710", "Налог на прибыль",
                                 (900_000 if ib == "airl" else 600_000) * f, doc_type="НачислениеНалогов",
                                 vat=False, pay_after=25, cf_article="Налоги")
                # банковское обслуживание
                self.expense(ib, m + timedelta(days=27), "SUP-bank", "7210.08", "Банковские комиссии",
                             15_000 if ib == "airl" else 9_000, vat=False)
            # реклама перед потоками (AIRL): больше в сезон, перерасход в текущем месяце
            ads = 2_600_000 * f
            if m >= add_months(month_start(T), -1):
                ads *= 1.4
            for k in range(3):
                self.expense("airl", m + timedelta(days=3 + 9 * k), "SUP-ads", "7110", "Реклама", ads / 3,
                             pay_after=1, cf_article="Оплата поставщикам")
            # те же деньги в рекламных кабинетах и таблице бюджета маркетинга — по дням и кампаниям;
            # бюджет (таблица маркетинга) — без перерасхода последних месяцев
            plan = 2_600_000 * f
            for ch, share in MKT_SHARES:
                self.rows["mkt_budget"].append(dict(month=m.isoformat(), channel=ch, budget=money(round(plan * share, -4))))
            self.ad_spend_month(m, sum(money(ads / 3) for _ in range(3)))
            # НДС к уплате за прошлый месяц (25-го): 12/112 продаж минус НДС поставщиков — только деньги
            pm = add_months(m, -1)
            if pm >= self.start:
                for ib in ("airl", "airl_dev"):
                    out_vat = sum(Decimal(r["sum_vat"]) for r in self.rows["realizatsiya"]
                                  if r["infobase"] == ib and r["date"][:7] == pm.strftime("%Y-%m"))
                    in_vat = sum(Decimal(r["sum_vat"]) for r in self.rows["zatraty"]
                                 if r["infobase"] == ib and r["date"][:7] == pm.strftime("%Y-%m"))
                    if out_vat - in_vat > 0:
                        self.payment_out(ib, m + timedelta(days=24), "SUP-budget", out_vat - in_vat, "Налоги")
            # дивиденды участникам — раз в квартал (финансовая деятельность)
            # (с отделами HR и маркетинга в штате ФОТ вырос — дивиденды участники уменьшили)
            if m.month in (3, 6, 9, 12):
                self.payment_out("airl", m + timedelta(days=20), "SUP-owner", 6_000_000, "Дивиденды")
                self.payment_out("airl_dev", m + timedelta(days=20), "SUP-owner", 3_500_000, "Дивиденды")
            m = add_months(m, 1)

        # Лиды без продажи (основная масса воронки) и повторные обращения
        for d in self.days(self.start, T):
            f = self.factor(d)
            for _ in range(int(self.rnd.uniform(4, 9) * f)):
                phone = self.phone()
                name = self.person_name()
                self.lead(d, phone, name)
                if self.rnd.random() < 0.06:  # дубль: тот же человек написал ещё раз
                    self.lead(d + timedelta(days=self.rnd.randint(1, 20)), phone, name)
            if self.rnd.random() < 0.25 * f:  # B2B-заявка без продажи
                c = self.rnd.choice(self.companies)
                self.lead(d, c["phone"], c["name"], company_bin=c["bin"])
        self.rows["leads"] = [l for l in self.rows["leads"] if l["created_at"][:10] < T.isoformat()]

        self.hr_sheets()

        # Строки выписки, которых нет в 1С: непонятный плательщик, частичная оплата, возврат
        unknown = [
            (T - timedelta(days=3), 245_000, "Физическое лицо (демо)", "991312345678", "Перевод по номеру телефона"),
            (T - timedelta(days=6), 1_120_000, "ТОО «Демо-Неизвестный 77»", "991499999977", "Оплата за обучение сотрудников"),
            (T - timedelta(days=12), 480_000, "ИП «Демо-Клиент»", "991488888811", "Предоплата по договору"),
            (T - timedelta(days=15), 77_500, "Физическое лицо (демо)", "991311112222", "Возврат подотчётных средств"),
        ]
        for d, amt, nm, bn, purpose in unknown:
            self.bank_line("airl", "BA-AIRL-1", d, amt, nm, bn, purpose, f"{self.rnd.randint(100, 9999)}")
        for k in range(1, 3):
            self.bank_line("airl", "BA-AIRL-1", month_start(T) - timedelta(days=1) if k == 1 else T - timedelta(days=1),
                           -15_000, "Демо Банк Алатау", "", "Комиссия за обслуживание счёта", f"К-{k}")

    # ---------- HR: штат, ЗУП, вакансии, отсутствия ----------
    def setup_hr(self, salary):
        """HR и маркетинг в штате, уходы и замены за 18 месяцев. Только hr_rnd."""
        R = self.hr_rnd
        salary.update({"HR-менеджер": 550_000, "Руководитель маркетинга": 950_000, "SMM-специалист": 400_000,
                       "Маркетолог-аналитик": 600_000, "Руководитель HR": 900_000})
        self.vacancy_plan = []   # (должность, отдел, открыта, закрыта|None, источник, табельный нанятого|None, статус)
        T = self.today
        n = len(self.employees)

        def add(dept, pos, hire, fire="", reason=""):
            nonlocal n
            n += 1
            ib = "airl_dev" if dept == "Разработка" else "airl"
            e = dict(infobase=ib, ref=f"EMP-{n:03d}", tab_no=f"{n:04d}",
                     fio=f"{R.choice(SURNAMES)} {R.choice(FIRST)}", podrazdelenie=dept, dolzhnost=pos,
                     hire_date=hire.isoformat(), fire_date=fire, oklad=salary[pos])
            self.rows["sotrudniki"].append(e)
            self.employees.append(e)
            return e

        def hired_via_vacancy(e, source=None):
            h = date.fromisoformat(e["hire_date"])
            if h <= self.start:
                return
            days = R.randint(16, 58)
            self.vacancy_plan.append((e["dolzhnost"], e["podrazdelenie"], h - timedelta(days=days), h,
                                      source or R.choice(SOURCES), e["tab_no"], "closed"))

        # Отделы HR и маркетинга (работали до начала истории)
        add("HR", "Руководитель HR", self.start - timedelta(days=R.randint(200, 700)))
        add("Маркетинг", "Руководитель маркетинга", self.start - timedelta(days=R.randint(200, 700)))
        # Найм в отделах за период
        hired_via_vacancy(add("HR", "HR-менеджер", self.start + timedelta(days=R.randint(60, 120))), "hh.kz")
        hired_via_vacancy(add("Маркетинг", "SMM-специалист", self.start + timedelta(days=R.randint(150, 260))), "Telegram-каналы")
        base = self.employees[:25]
        # Уже нанятые в периоде (i >= 20 основного списка) — через вакансии
        for e in base:
            hired_via_vacancy(e)
        # Ушедшие из основного списка — замена через вакансию
        for e in base:
            if e["fire_date"]:
                fd = date.fromisoformat(e["fire_date"])
                opened = fd - timedelta(days=14)          # уведомление за 2 недели
                hire = opened + timedelta(days=R.randint(25, 60))
                if hire < T:
                    r = add(e["podrazdelenie"], e["dolzhnost"], hire)
                    self.vacancy_plan.append((r["dolzhnost"], r["podrazdelenie"], opened, hire, R.choice(SOURCES), r["tab_no"], "closed"))
                else:
                    self.vacancy_plan.append((e["dolzhnost"], e["podrazdelenie"], opened, None, R.choice(SOURCES), None, "open"))
        # Текучесть: преподаватель и инженер пришли до истории и ушли в периоде; один уход — в прошлом месяце
        for dept, pos, lo, hi in [("Обучение", "Преподаватель", 120, 240), ("Разработка", "Инженер ИИ", 300, 420),
                                  ("Продажи", "Менеджер по продажам", (T - self.start).days - 40, (T - self.start).days - 25)]:
            fd = self.start + timedelta(days=R.randint(lo, hi))
            e = add(dept, pos, self.start - timedelta(days=R.randint(120, 600)), fd.isoformat())
            opened = fd - timedelta(days=14)
            hire = opened + timedelta(days=R.randint(28, 70))
            if hire < T - timedelta(days=3):
                r = add(dept, pos, hire)
                self.vacancy_plan.append((pos, dept, opened, hire, R.choice(SOURCES), r["tab_no"], "closed"))
            else:
                self.vacancy_plan.append((pos, dept, opened, None, R.choice(SOURCES), None, "open"))
        # Рост осенью: куратор под новые потоки и менеджер по продажам — недавно пришли, онбординг идёт
        for dept, pos, lo, hi in [("Обучение", "Куратор потока", 70, 55), ("Продажи", "Менеджер по продажам", 30, 20)]:
            hire = T - timedelta(days=R.randint(hi, lo))
            r = add(dept, pos, hire)
            self.vacancy_plan.append((pos, dept, hire - timedelta(days=R.randint(24, 48)), hire, R.choice(SOURCES), r["tab_no"], "closed"))
        # Новые позиции: открыты сейчас (одна — давно, без откликов), одна отменена
        self.vacancy_plan.append(("Маркетолог-аналитик", "Маркетинг", T - timedelta(days=R.randint(50, 64)), None, "hh.kz", None, "open"))
        self.vacancy_plan.append(("Куратор потока", "Обучение", T - timedelta(days=R.randint(8, 15)), None, "Рекомендация", None, "open"))
        self.vacancy_plan.append(("Инженер ИИ", "Разработка", T - timedelta(days=R.randint(20, 30)), None, "LinkedIn", None, "open"))
        self.vacancy_plan.append(("Бухгалтер", "Финансы", self.start + timedelta(days=200), self.start + timedelta(days=245), "hh.kz", None, "cancelled"))

    def payroll_month(self, ib, m, me, final):
        """Начисления ЗУП за месяц по сотрудникам юрлица (оклад + налоги работодателя 11,5 %).
        Возвращает сумму для проводки в 1С:Бухгалтерии."""
        total = Decimal(0)
        for e in self.employees:
            if e["infobase"] != ib:
                continue
            h = date.fromisoformat(e["hire_date"])
            fd = date.fromisoformat(e["fire_date"]) if e["fire_date"] else None
            if not (h <= me and (fd is None or fd >= m)):
                continue
            acc = money(e["oklad"])
            tax = money(Decimal(e["oklad"]) * Decimal("0.115"))
            self.rows["zup_nachisleniya"].append(dict(
                infobase=ib, tab_no=e["tab_no"], month=m.isoformat(), podrazdelenie=e["podrazdelenie"],
                nachisleno=acc, nalogi_rabotodatelya=tax, status="final" if final else "plan"))
            total += acc + tax
        return total

    def hr_sheets(self):
        """Таблица вакансий HR и отсутствия ЗУП (отпуска, больничные) — после всего штата."""
        R = self.hr_rnd
        T = self.today
        for k, (pos, dept, opened, closed, source, tab, status) in enumerate(sorted(self.vacancy_plan, key=lambda v: v[2]), 1):
            self.rows["vacancies"].append(dict(
                vacancy_id=f"VAC-{k:03d}", position=pos, department=dept, opened=opened.isoformat(),
                closed=closed.isoformat() if closed else "", status=status, source=source, hired_tab_no=tab or "",
                candidates=R.randint(6, 40) if status != "cancelled" else R.randint(2, 6)))
        n = 0
        for e in self.employees:
            h = max(date.fromisoformat(e["hire_date"]), self.start)
            fd = date.fromisoformat(e["fire_date"]) if e["fire_date"] else T - timedelta(days=1)
            m = month_start(h)
            while m <= fd:
                last = min(month_end(m), fd)
                # отпуск: летом и в декабре чаще; больничный — 1–2 раза в год
                p_vac = 0.32 if m.month in (6, 7, 8) else 0.18 if m.month == 12 else 0.07
                for kind, p, lo, hi in [("Отпуск", p_vac, 5, 14), ("Больничный", 0.09, 2, 7)]:
                    if R.random() < p and (last - m).days >= 3:
                        d0 = m + timedelta(days=R.randint(0, max(0, (last - m).days - 2)))
                        d1 = min(d0 + timedelta(days=R.randint(lo, hi) - 1), last)
                        if d0 < h or d0 >= T:
                            continue
                        n += 1
                        self.rows["zup_otsutstviya"].append(dict(
                            infobase=e["infobase"], ref=f"OTS-{n:05d}", tab_no=e["tab_no"], kind=kind,
                            date_from=d0.isoformat(), date_to=d1.isoformat()))
                m = add_months(m, 1)

    # ---------- маркетинг: кампании и расход рекламных кабинетов ----------
    def campaign_for(self, ch, d):
        """utm_campaign заявки: кампании канала в месяце заявки (только mkt_rnd)."""
        key = (ch, d.strftime("%Y-%m"))
        if key not in self.campaigns:
            ym = d.strftime("%y%m")
            names = {"instagram": [f"ig_vibeops_{ym}", f"ig_corp_ai_{ym}"], "site": [f"google_search_{ym}"],
                     "telegram": [f"tg_channels_{ym}"], "meta_form": [f"meta_leadform_{ym}"],
                     "event": [f"event_meetup_{ym}"], "referral": ["referral_program"]}[ch]
            self.campaigns[key] = names
        return self.mkt_rnd.choice(self.campaigns[key])

    def ad_spend_month(self, m, total):
        """Расход месяца (= проводки «Реклама» в 1С за закрытый месяц) по каналам, кампаниям и дням."""
        R = self.mkt_rnd
        T = self.today
        shares = dict(MKT_SHARES)
        if R.random() < 0.4:   # мероприятий в этом месяце не было
            shares.pop("event")
        w = {c: s * R.uniform(0.85, 1.15) for c, s in shares.items()}
        sw = sum(w.values())
        chans = list(w)
        alloc, left = {}, total
        for c in chans[:-1]:
            alloc[c] = money(total * Decimal(w[c] / sw))
            left -= alloc[c]
        alloc[chans[-1]] = left
        last = month_end(m)
        days = (last - m).days + 1
        for c in chans:
            self.campaign_for(c, m)   # список кампаний канала в месяце
            names = self.campaigns[(c, m.strftime("%Y-%m"))]
            per = {nm: money(alloc[c] / len(names)) for nm in names}
            per[names[-1]] = alloc[c] - sum(per[x] for x in names[:-1])
            for nm in names:
                if nm not in self.campaign_seen:
                    self.campaign_seen.add(nm)
                    self.rows["ad_campaigns"].append(dict(
                        utm_campaign=nm, channel=c, cabinet=CABINET[c], title=campaign_title(nm, c),
                        start_date=m.isoformat(), end_date=last.isoformat() if nm != "referral_program" else ""))
                amt = per[nm]
                if c == "event":   # мероприятие — один день оплаты
                    ev = m + timedelta(days=R.randint(8, 20))
                    if ev < T:
                        self.rows["ad_spend"].append(dict(date=ev.isoformat(), cabinet=CABINET[c], channel=c,
                                                          utm_campaign=nm, spend=amt, impressions=0, clicks=0))
                    continue
                acc = Decimal(0)
                for i in range(days):
                    d = m + timedelta(days=i)
                    v = amt - acc if i == days - 1 else money(amt / days * Decimal(R.uniform(0.7, 1.3)))
                    if i < days - 1 and acc + v > amt:
                        v = max(Decimal(0), amt - acc)
                    acc += v
                    if d >= T or v <= 0:
                        continue
                    imp = int(float(v) / R.uniform(0.9, 1.6)) if c != "referral" else 0
                    self.rows["ad_spend"].append(dict(date=d.isoformat(), cabinet=CABINET[c], channel=c, utm_campaign=nm,
                                                      spend=v, impressions=imp, clicks=int(imp * R.uniform(0.008, 0.025))))

    def write(self, out):
        os.makedirs(out, exist_ok=True)
        for name, rows in self.rows.items():
            if not rows:
                continue
            with open(os.path.join(out, f"{name}.csv"), "w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)
        with open(os.path.join(out, "_meta.csv"), "w", encoding="utf-8") as fh:
            fh.write("key,value\n")
            fh.write(f"today,{self.today.isoformat()}\n")
            fh.write(f"history_start,{self.start.isoformat()}\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    p.add_argument("--seed", type=int, default=20261)
    a = p.parse_args()
    today = date.fromisoformat(os.environ["DEMO_TODAY"]) if os.environ.get("DEMO_TODAY") \
        else datetime.now(ALMATY).date()
    g = Gen(today, a.seed)
    g.run()
    g.write(a.out)
    print(f"Синтетические данные на {today}: " + ", ".join(f"{k}={len(v)}" for k, v in g.rows.items()))


if __name__ == "__main__":
    main()
