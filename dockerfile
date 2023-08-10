FROM node:16

# Create app directory
WORKDIR .

# Install app dependencies
# A wildcard is used to ensure both package.json AND package-lock.json are copied
# where available (npm@5+)
COPY src/package*.json ./

RUN npm install

# Bundle app source
COPY src/index.js .

EXPOSE 8080
CMD [ "npm", "start", "run" ]