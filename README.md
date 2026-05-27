# 1. activate venv first
source venv/bin/activate

# 2. install
pip install -r requirements.txt

# 3. lock versions
pip freeze > requirements.txt

# 4. run the script
PYTHONPATH=. python scripts/fetch_data.py

zip -r dota2metalab-infra.zip .gitignore argocd-apps infrastructure k8s Makefile deploy cli