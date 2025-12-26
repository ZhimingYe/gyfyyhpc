FROM rocker/geospatial:latest

# Install SSH and htop
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server sudo wget htop && \
    rm -rf /var/lib/apt/lists/*

# Set up SSH - 允许密码登录
RUN mkdir -p /var/run/sshd && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Password-less sudo
RUN echo "rstudio ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Miniforge
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/miniforge.sh && \
    bash /tmp/miniforge.sh -b -p /home/rstudio/miniforge3 && \
    rm /tmp/miniforge.sh && \
    chown -R rstudio:rstudio /home/rstudio/miniforge3

# Initialize conda
RUN su - rstudio -c "/home/rstudio/miniforge3/bin/conda init bash" && \
    su - rstudio -c "/home/rstudio/miniforge3/bin/conda config --set auto_activate_base false"

RUN mkdir -p /home/rstudio/PersonalData && \
    chown -R rstudio:rstudio /home/rstudio/PersonalData


# 配置 bashrc: 欢迎信息 + 自动激活 conda base 环境
RUN echo '' >> /home/rstudio/.bashrc && \
    echo '# 欢迎信息' >> /home/rstudio/.bashrc && \
    echo 'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"' >> /home/rstudio/.bashrc && \
    echo 'echo "  欢迎来到广州医科大学胸外科高性能计算节点"' >> /home/rstudio/.bashrc && \
    echo 'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"' >> /home/rstudio/.bashrc && \
    echo 'echo ""' >> /home/rstudio/.bashrc && \
    echo '# 自动激活 conda base 环境' >> /home/rstudio/.bashrc && \
    echo 'conda activate base' >> /home/rstudio/.bashrc

EXPOSE 22 8787

CMD service ssh start && /init
